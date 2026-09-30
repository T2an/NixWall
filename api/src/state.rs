use std::sync::{Arc, Mutex};

use tokio::sync::RwLock;

use crate::auth::token::ApiTokenRecord;
use crate::config::Config;

pub type TokenStore = Arc<RwLock<Vec<ApiTokenRecord>>>;

pub struct AppCtx {
    pub cfg: Config,
    pub ticket_secret: Vec<u8>,
    pub tokens: TokenStore,
    pub secrets_yaml_lock: Arc<Mutex<()>>,
}

pub type AppState = Arc<AppCtx>;
