mod api;
mod crypto;
mod db;
mod notifications;
mod state;
mod sync;
mod tor;

use serde_json::Value;
use state::AppState;
use std::path::PathBuf;
use std::sync::Arc;
use tauri::Manager;
use tokio::sync::RwLock;

use crate::api::client::ApiClient;
use crate::crypto::keystore::KeyStore;
use crate::db::Database;
use crate::sync::qr::{DeviceLinker, EncryptedLinkPayload, QrCodeData};
use crate::tor::TorStatus;

// ========== Auth Commands ==========

#[tauri::command]
async fn get_auth_status(state: tauri::State<'_, AppState>) -> Result<state::AuthState, String> {
    let auth = state.auth.read().await;
    Ok(auth.clone())
}

#[tauri::command]
async fn start_device_link(
    linker: tauri::State<'_, Arc<RwLock<DeviceLinker>>>,
) -> Result<QrCodeData, String> {
    let mut linker = linker.write().await;
    linker.generate_qr()
}

#[tauri::command]
async fn poll_device_link(
    device_id: String,
    state: tauri::State<'_, AppState>,
    linker: tauri::State<'_, Arc<RwLock<DeviceLinker>>>,
) -> Result<Option<Value>, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;

    match api.poll_device_link(&device_id).await {
        Ok(resp) => {
            // Check if we got an encrypted payload
            if let Some(payload_str) = resp.get("encrypted_payload").and_then(|v| v.as_str()) {
                if !payload_str.is_empty() {
                    let encrypted: EncryptedLinkPayload =
                        serde_json::from_str(payload_str)
                            .map_err(|e| format!("Parse encrypted payload: {}", e))?;

                    let linker = linker.read().await;
                    let link_result = linker.decrypt_payload(&encrypted)?;

                    // Update auth state
                    let mut auth = state.auth.write().await;
                    auth.is_authenticated = true;
                    auth.user_id = Some(link_result.user_id.clone());
                    auth.token = Some(link_result.token.clone());
                    auth.device_id = Some(device_id);

                    // Update API client token
                    let mut api = state.api.write().await;
                    if let Some(client) = api.as_mut() {
                        client.set_token(link_result.token);
                    }

                    return Ok(Some(serde_json::json!({
                        "linked": true,
                        "user_id": link_result.user_id,
                    })));
                }
            }
            Ok(None) // No payload yet, keep polling
        }
        Err(e) => {
            if e.contains("404") {
                Ok(None) // Not found yet, keep polling
            } else {
                Err(e)
            }
        }
    }
}

#[tauri::command]
async fn try_restore_session(state: tauri::State<'_, AppState>) -> Result<bool, String> {
    // Try to load credentials from keychain
    let token = match KeyStore::get_token() {
        Ok(t) => t,
        Err(_) => return Ok(false),
    };
    let user_id = match KeyStore::get_user_id() {
        Ok(u) => u,
        Err(_) => return Ok(false),
    };

    // Verify token is still valid by calling /me
    let mut api = state.api.write().await;
    if let Some(client) = api.as_mut() {
        client.set_token(token.clone());
        match client.get_me().await {
            Ok(profile) => {
                let mut auth = state.auth.write().await;
                auth.is_authenticated = true;
                auth.user_id = Some(profile.id);
                auth.trust_score = Some(profile.trust_score);
                auth.token = Some(token);
                Ok(true)
            }
            Err(_) => {
                // Token expired, clear it
                let _ = KeyStore::delete("auth_token");
                Ok(false)
            }
        }
    } else {
        Ok(false)
    }
}

#[tauri::command]
async fn logout(state: tauri::State<'_, AppState>) -> Result<(), String> {
    let mut auth = state.auth.write().await;
    *auth = state::AuthState::default();
    let _ = KeyStore::delete("auth_token");
    Ok(())
}

#[tauri::command]
async fn panic_wipe(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    // Clear auth state
    let mut auth = state.auth.write().await;
    *auth = state::AuthState::default();

    // Wipe OS keychain
    KeyStore::wipe_all()?;

    // Wipe local database
    let db = state.db.read().await;
    if let Some(database) = db.as_ref() {
        database.wipe()?;
    }

    // Delete database file
    if let Some(app_dir) = app.path().app_data_dir().ok() {
        let db_path = app_dir.join("kuurier.db");
        let _ = std::fs::remove_file(&db_path);

        // Delete Tor data
        let tor_dir = app_dir.join("tor");
        let _ = std::fs::remove_dir_all(&tor_dir);
    }

    log::info!("Panic wipe completed");
    Ok(())
}

// ========== Tor Commands ==========

#[tauri::command]
async fn get_tor_status(state: tauri::State<'_, AppState>) -> Result<TorStatus, String> {
    let tor = state.tor.read().await;
    Ok(tor.status.clone())
}

#[tauri::command]
async fn restart_tor(state: tauri::State<'_, AppState>) -> Result<TorStatus, String> {
    let mut tor = state.tor.write().await;
    tor.set_enabled(true);
    tor.start().await?;
    Ok(tor.status.clone())
}

#[tauri::command]
async fn set_tor_enabled(
    enabled: bool,
    state: tauri::State<'_, AppState>,
) -> Result<TorStatus, String> {
    let mut tor = state.tor.write().await;
    tor.set_enabled(enabled);
    if enabled {
        tor.start().await?;
    } else {
        tor.stop().await;
    }

    // Rebuild API client with/without proxy
    let proxy_url = tor.proxy_url();
    let config = state.config.read().await;
    let mut api = state.api.write().await;
    *api = Some(ApiClient::new(&config.api_base_url, proxy_url.as_deref())?);

    // Restore token if authenticated
    let auth = state.auth.read().await;
    if let Some(token) = &auth.token {
        if let Some(client) = api.as_mut() {
            client.set_token(token.clone());
        }
    }

    Ok(tor.status.clone())
}

// ========== Feed Commands ==========

#[tauri::command]
async fn fetch_feed(
    feed_type: String,
    offset: u32,
    state: tauri::State<'_, AppState>,
) -> Result<Value, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;
    api.fetch_feed(&feed_type, offset).await
}

#[tauri::command]
async fn create_post(
    content: String,
    source_type: String,
    state: tauri::State<'_, AppState>,
) -> Result<Value, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;
    api.create_post(&content, &source_type).await
}

#[tauri::command]
async fn verify_post(id: String, state: tauri::State<'_, AppState>) -> Result<Value, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;
    api.post(&format!("/feed/posts/{}/verify", id), &serde_json::json!({}))
        .await
}

#[tauri::command]
async fn flag_post(id: String, state: tauri::State<'_, AppState>) -> Result<Value, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;
    api.post(&format!("/feed/posts/{}/flag", id), &serde_json::json!({}))
        .await
}

// ========== Profile Commands ==========

#[tauri::command]
async fn get_me(state: tauri::State<'_, AppState>) -> Result<Value, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;
    let profile = api.get_me().await?;
    serde_json::to_value(profile).map_err(|e| e.to_string())
}

#[tauri::command]
async fn set_display_name(name: String, state: tauri::State<'_, AppState>) -> Result<Value, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;
    api.set_display_name(&name).await
}

// ========== Messaging Commands ==========

#[tauri::command]
async fn list_channels(state: tauri::State<'_, AppState>) -> Result<Value, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;
    let channels = api.list_channels().await?;
    Ok(serde_json::to_value(channels).map_err(|e| e.to_string())?)
}

#[tauri::command]
async fn get_messages(
    channel_id: String,
    before: Option<String>,
    state: tauri::State<'_, AppState>,
) -> Result<Value, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;
    let messages = api.get_messages(&channel_id, before.as_deref()).await?;
    Ok(serde_json::to_value(messages).map_err(|e| e.to_string())?)
}

#[tauri::command]
async fn send_message(
    channel_id: String,
    content: String,
    state: tauri::State<'_, AppState>,
) -> Result<Value, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;
    // TODO: Encrypt with Signal Protocol before sending
    api.send_message(&channel_id, &content).await
}

#[tauri::command]
async fn create_dm(user_id: String, state: tauri::State<'_, AppState>) -> Result<Value, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;
    let channel = api.create_dm(&user_id).await?;
    Ok(serde_json::to_value(channel).map_err(|e| e.to_string())?)
}

// ========== Events Commands ==========

#[tauri::command]
async fn list_events(state: tauri::State<'_, AppState>) -> Result<Value, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;
    api.list_events().await
}

#[tauri::command]
async fn create_event(event: Value, state: tauri::State<'_, AppState>) -> Result<Value, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;
    api.create_event(&event).await
}

// ========== Alerts Commands ==========

#[tauri::command]
async fn list_alerts(state: tauri::State<'_, AppState>) -> Result<Value, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;
    api.list_alerts().await
}

#[tauri::command]
async fn create_alert(alert: Value, state: tauri::State<'_, AppState>) -> Result<Value, String> {
    let api = state.api.read().await;
    let api = api.as_ref().ok_or("API client not initialized")?;
    api.create_alert(&alert).await
}

// ========== Settings Commands ==========

#[tauri::command]
async fn get_config(state: tauri::State<'_, AppState>) -> Result<state::AppConfig, String> {
    let config = state.config.read().await;
    Ok(config.clone())
}

#[tauri::command]
async fn set_api_url(
    url: String,
    state: tauri::State<'_, AppState>,
) -> Result<(), String> {
    let mut config = state.config.write().await;
    config.api_base_url = url.clone();

    // Rebuild API client
    let tor = state.tor.read().await;
    let proxy_url = tor.proxy_url();
    let mut api = state.api.write().await;
    *api = Some(ApiClient::new(&url, proxy_url.as_deref())?);

    Ok(())
}

// ========== App Entry Point ==========

pub fn run() {
    env_logger::init();

    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
            let app_state = AppState::new();

            // Initialize API client (no Tor by default in dev)
            let config = app_state.config.blocking_read();
            let api_client = ApiClient::new(&config.api_base_url, None)
                .expect("Failed to create API client");
            drop(config);

            {
                let mut api = app_state.api.blocking_write();
                *api = Some(api_client);
            }

            // Initialize local database
            if let Ok(app_dir) = app.path().app_data_dir() {
                std::fs::create_dir_all(&app_dir).ok();
                let db_path = app_dir.join("kuurier.db");
                match Database::open(&db_path) {
                    Ok(database) => {
                        let mut db = app_state.db.blocking_write();
                        *db = Some(database);
                        log::info!("Database opened at {:?}", db_path);
                    }
                    Err(e) => {
                        log::error!("Failed to open database: {}", e);
                    }
                }
            }

            app.manage(app_state);
            app.manage(Arc::new(RwLock::new(DeviceLinker::new())));

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            // Auth
            get_auth_status,
            start_device_link,
            poll_device_link,
            try_restore_session,
            logout,
            panic_wipe,
            // Tor
            get_tor_status,
            restart_tor,
            set_tor_enabled,
            // Feed
            fetch_feed,
            create_post,
            verify_post,
            flag_post,
            // Profile
            get_me,
            set_display_name,
            // Messaging
            list_channels,
            get_messages,
            send_message,
            create_dm,
            // Events
            list_events,
            create_event,
            // Alerts
            list_alerts,
            create_alert,
            // Settings
            get_config,
            set_api_url,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Kuurier");
}
