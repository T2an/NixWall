use std::path::Path;

use axum::{
    Extension, Json,
    extract::{Path as AxumPath, State},
    http::StatusCode,
    response::Response,
};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::auth::principal::Principal;
use crate::state::AppState;
use crate::util::{api_error, run, run_with_stdin};

use super::apply::queue_apply;

#[derive(Deserialize)]
pub struct PasswordBody {
    pub password: String,
}

fn provisioned_secret_key(ctx: &AppState, name: &str) -> Option<String> {
    let s = std::fs::read_to_string(&ctx.cfg.config_path).ok()?;
    let v: Value = toml::from_str(&s).ok()?;
    let path = v
        .get("users")?
        .get(name)?
        .get("passwordHashFile")?
        .as_str()?;
    let key = Path::new(path).file_name()?.to_string_lossy().into_owned();
    if key
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        Some(key)
    } else {
        None
    }
}

pub async fn change_password(
    State(ctx): State<AppState>,
    Extension(principal): Extension<Principal>,
    AxumPath(name): AxumPath<String>,
    Json(body): Json<PasswordBody>,
) -> Response {
    if principal.user() != name {
        return api_error(StatusCode::FORBIDDEN, "can only change your own password");
    }

    if body.password.is_empty() || body.password.contains('\n') {
        return api_error(
            StatusCode::BAD_REQUEST,
            "password must be non-empty and must not contain a newline",
        );
    }

    let Some(secret_key) = provisioned_secret_key(&ctx, &name) else {
        return api_error(
            StatusCode::BAD_REQUEST,
            format!(
                "{name} has no passwordHashFile in config.toml — not provisioned for password management"
            ),
        );
    };

    let stdin_input = format!("{}\n", body.password);
    let hash_out = match run_with_stdin(
        &[&ctx.cfg.mkpasswd_bin, "-m", "sha-512", "-s"],
        stdin_input.as_bytes(),
    ) {
        Ok(out) => out,
        Err(e) => {
            return api_error(
                StatusCode::INTERNAL_SERVER_ERROR,
                json!({"message": "failed to run mkpasswd", "error": e.to_string()}),
            );
        }
    };
    if !hash_out.status.success() {
        return api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            json!({
                "message": "mkpasswd failed",
                "stderr": String::from_utf8_lossy(&hash_out.stderr),
            }),
        );
    }
    let hash = String::from_utf8_lossy(&hash_out.stdout).trim().to_owned();

    let set_expr = format!("[\"{secret_key}\"] {}", json!(hash));
    let sops_out = {
        let _guard = ctx
            .secrets_yaml_lock
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        run(
            &[
                &ctx.cfg.sops_bin,
                "--set",
                &set_expr,
                &ctx.cfg.secrets_yaml_path,
            ],
            None,
        )
    };
    if !sops_out.status.success() {
        return api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            json!({
                "message": "sops --set failed",
                "stderr": String::from_utf8_lossy(&sops_out.stderr),
            }),
        );
    }

    queue_apply(&ctx, "switch", None, Vec::new())
}
