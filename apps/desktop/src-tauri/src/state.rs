use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::api::client::ApiClient;
use crate::db::Database;
use crate::tor::TorProxy;

/// Global application state shared across all Tauri commands.
pub struct AppState {
    pub tor: Arc<RwLock<TorProxy>>,
    pub api: Arc<RwLock<Option<ApiClient>>>,
    pub db: Arc<RwLock<Option<Database>>>,
    pub auth: Arc<RwLock<AuthState>>,
    pub config: Arc<RwLock<AppConfig>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthState {
    pub is_authenticated: bool,
    pub user_id: Option<String>,
    pub trust_score: Option<i32>,
    pub device_id: Option<String>,
    pub token: Option<String>,
}

impl Default for AuthState {
    fn default() -> Self {
        Self {
            is_authenticated: false,
            user_id: None,
            trust_score: None,
            device_id: None,
            token: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    pub api_base_url: String,
    pub tor_enabled: bool,
    pub socks_port: u16,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            api_base_url: "http://localhost:8080/api/v1".to_string(),
            tor_enabled: false,
            socks_port: 9150,
        }
    }
}

impl AppState {
    pub fn new() -> Self {
        Self {
            tor: Arc::new(RwLock::new(TorProxy::new())),
            api: Arc::new(RwLock::new(None)),
            db: Arc::new(RwLock::new(None)),
            auth: Arc::new(RwLock::new(AuthState::default())),
            config: Arc::new(RwLock::new(AppConfig::default())),
        }
    }
}
