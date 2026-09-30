use axum::{
    Json,
    extract::{Path as AxumPath, Query, State},
    http::{StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::config::Config;
use crate::state::AppState;
use crate::util::{api_error, run};

fn detect_attr(cfg: &Config, preferred: Option<&str>) -> String {
    if let Some(p) = preferred {
        return p.to_owned();
    }
    let out = run(
        &[
            &cfg.nix_bin,
            "eval",
            "--json",
            &format!("{}#nixosConfigurations", cfg.flake),
            "--apply",
            "builtins.attrNames",
        ],
        None,
    );
    if !out.status.success() {
        return "nixwall".into();
    }
    let names: Vec<String> = serde_json::from_slice(&out.stdout).unwrap_or_default();
    if names.contains(&"nixwall".to_owned()) {
        return "nixwall".into();
    }
    if names.contains(&"machine".to_owned()) {
        return "machine".into();
    }
    names.into_iter().next().unwrap_or_else(|| "nixwall".into())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplyBody {
    #[serde(default = "default_mode")]
    pub mode: String,
    pub attr: Option<String>,
    pub extra_args: Option<Vec<String>>,
}
fn default_mode() -> String {
    "switch".into()
}

pub async fn apply_config(State(ctx): State<AppState>, Json(body): Json<ApplyBody>) -> Response {
    let mode = &body.mode;
    if !["switch", "boot", "test"].contains(&mode.as_str()) {
        return api_error(
            StatusCode::BAD_REQUEST,
            "mode must be one of: switch, boot, test",
        );
    }

    queue_apply(
        &ctx,
        mode,
        body.attr.as_deref(),
        body.extra_args.unwrap_or_default(),
    )
}

pub fn queue_apply(ctx: &AppState, mode: &str, attr: Option<&str>, extra: Vec<String>) -> Response {
    let target = detect_attr(&ctx.cfg, attr);
    let job_id = Uuid::new_v4().simple().to_string()[..10].to_owned();
    let unit = format!("nixwall-apply-{job_id}.service");
    let flake_target = format!("{}#{}", ctx.cfg.flake, target);

    let mut cmd_owned: Vec<String> = vec![
        ctx.cfg.sdr_bin.clone(),
        "--unit".into(),
        unit.clone(),
        "--description".into(),
        "NixWall apply via API".into(),
        "--property".into(),
        "After=network-online.target".into(),
        "--property".into(),
        "Wants=network-online.target".into(),
    ];
    // systemd-run's transient unit does not inherit nixwall-api's own PATH --
    // it gets systemd's bare default one. nixos-rebuild-ng shells out to
    // plain command names (e.g. "test") internally, which then fail to
    // resolve under that default PATH even though nxr_bin itself is an
    // absolute path and starts fine.
    if let Ok(path) = std::env::var("PATH") {
        cmd_owned.push("--setenv".into());
        cmd_owned.push(format!("PATH={path}"));
    }
    cmd_owned.extend([
        ctx.cfg.nxr_bin.clone(),
        mode.to_owned(),
        "--flake".into(),
        flake_target,
        "-L".into(),
        // The appliance is offline by default and /etc/nixos's flake.lock is
        // fully pinned at install time; nix would otherwise try to refresh
        // it (needing git and network access) on every apply.
        "--no-update-lock-file".into(),
    ]);
    cmd_owned.extend(extra);

    let cmd_refs: Vec<&str> = cmd_owned.iter().map(|s| s.as_str()).collect();
    let out = run(&cmd_refs, None);
    if !out.status.success() {
        return api_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            json!({
                "message": "systemd-run failed",
                "rc": out.status.code().unwrap_or(-1),
                "stderr": String::from_utf8_lossy(&out.stderr),
                "stdout": String::from_utf8_lossy(&out.stdout),
            }),
        );
    }

    (
        StatusCode::ACCEPTED,
        Json(json!({
            "status": "queued",
            "id": job_id,
            "unit": unit,
            "mode": mode,
            "attr": target,
        })),
    )
        .into_response()
}

fn unit_status(cfg: &Config, unit: &str) -> Option<Value> {
    let out = run(
        &[
            &cfg.sct_bin,
            "show",
            unit,
            "-p",
            "LoadState",
            "-p",
            "ActiveState",
            "-p",
            "SubState",
            "-p",
            "ExecMainStatus",
            "-p",
            "Result",
        ],
        None,
    );
    if !out.status.success() {
        return None;
    }
    let mut map = serde_json::Map::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        if let Some((k, v)) = line.split_once('=') {
            let val = if k == "ExecMainStatus" {
                v.parse::<i64>()
                    .map(Value::from)
                    .unwrap_or_else(|_| Value::String(v.into()))
            } else {
                Value::String(v.into())
            };
            map.insert(k.to_owned(), val);
        }
    }
    // systemd-run's --collect unloads the transient unit shortly after it
    // finishes; querying it after that point returns blank/default property
    // values (ActiveState=inactive, ExecMainStatus=0) that look like a quiet
    // success even when the job actually failed, so treat "gone" as unknown.
    if map.get("LoadState").and_then(Value::as_str) == Some("not-found") {
        return None;
    }
    Some(Value::Object(map))
}

pub async fn apply_status(
    State(ctx): State<AppState>,
    AxumPath(job_id): AxumPath<String>,
) -> Response {
    let unit = format!("nixwall-apply-{job_id}.service");
    match unit_status(&ctx.cfg, &unit) {
        Some(status) => Json(json!({"id": job_id, "unit": unit, "status": status})).into_response(),
        None => api_error(StatusCode::NOT_FOUND, "unit not found"),
    }
}

#[derive(Deserialize)]
pub struct LogsQuery {
    #[serde(default = "default_lines")]
    pub lines: u32,
}
fn default_lines() -> u32 {
    200
}

pub async fn apply_logs(
    State(ctx): State<AppState>,
    AxumPath(job_id): AxumPath<String>,
    Query(q): Query<LogsQuery>,
) -> Response {
    let lines = q.lines.clamp(1, 5000).to_string();
    let unit = format!("nixwall-apply-{job_id}.service");
    let out = run(
        &[
            &ctx.cfg.jct_bin,
            "-u",
            &unit,
            "--no-pager",
            "--output=short-iso",
            "-n",
            &lines,
        ],
        None,
    );
    if !out.status.success() {
        return api_error(StatusCode::NOT_FOUND, "unit not found or no logs");
    }
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/plain")],
        String::from_utf8_lossy(&out.stdout).into_owned(),
    )
        .into_response()
}
