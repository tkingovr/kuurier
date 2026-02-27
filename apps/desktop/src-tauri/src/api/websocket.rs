use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WsMessage {
    #[serde(rename = "type")]
    pub msg_type: String,
    #[serde(flatten)]
    pub payload: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum WsStatus {
    Disconnected,
    Connecting,
    Connected,
    Reconnecting(u32), // attempt number
    Error(String),
}

/// WebSocket client that connects to the Kuurier server through Tor.
pub struct WebSocketClient {
    pub status: Arc<RwLock<WsStatus>>,
    sender: Option<mpsc::Sender<String>>,
    shutdown: Option<mpsc::Sender<()>>,
}

impl WebSocketClient {
    pub fn new() -> Self {
        Self {
            status: Arc::new(RwLock::new(WsStatus::Disconnected)),
            sender: None,
            shutdown: None,
        }
    }

    /// Connect to the WebSocket server.
    /// Messages received from the server are forwarded to `on_message`.
    pub async fn connect<F>(
        &mut self,
        ws_url: &str,
        token: &str,
        proxy_url: Option<&str>,
        on_message: F,
    ) -> Result<(), String>
    where
        F: Fn(WsMessage) + Send + Sync + 'static,
    {
        let url = format!("{}?token={}", ws_url, token);

        *self.status.write().await = WsStatus::Connecting;

        // Connect (with optional SOCKS5 proxy for Tor)
        let (ws_stream, _) = if let Some(_proxy) = proxy_url {
            // TODO: Route through SOCKS5 proxy for Tor
            tokio_tungstenite::connect_async(&url)
                .await
                .map_err(|e| format!("WebSocket connect failed: {}", e))?
        } else {
            tokio_tungstenite::connect_async(&url)
                .await
                .map_err(|e| format!("WebSocket connect failed: {}", e))?
        };

        *self.status.write().await = WsStatus::Connected;
        log::info!("WebSocket connected");

        let (mut write, mut read) = ws_stream.split();

        // Channel for sending messages to the server
        let (tx, mut rx) = mpsc::channel::<String>(100);
        self.sender = Some(tx);

        // Channel for shutdown
        let (shutdown_tx, mut shutdown_rx) = mpsc::channel::<()>(1);
        self.shutdown = Some(shutdown_tx);

        let status = self.status.clone();

        // Spawn writer task
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    Some(msg) = rx.recv() => {
                        if let Err(e) = write.send(tokio_tungstenite::tungstenite::Message::Text(msg.into())).await {
                            log::error!("WebSocket send error: {}", e);
                            break;
                        }
                    }
                    _ = shutdown_rx.recv() => {
                        let _ = write.close().await;
                        break;
                    }
                }
            }
        });

        // Spawn reader task
        let status_clone = status.clone();
        tokio::spawn(async move {
            while let Some(msg) = read.next().await {
                match msg {
                    Ok(tokio_tungstenite::tungstenite::Message::Text(text)) => {
                        if let Ok(ws_msg) = serde_json::from_str::<WsMessage>(&text) {
                            on_message(ws_msg);
                        }
                    }
                    Ok(tokio_tungstenite::tungstenite::Message::Close(_)) => {
                        log::info!("WebSocket closed by server");
                        *status_clone.write().await = WsStatus::Disconnected;
                        break;
                    }
                    Err(e) => {
                        log::error!("WebSocket read error: {}", e);
                        *status_clone.write().await = WsStatus::Error(e.to_string());
                        break;
                    }
                    _ => {}
                }
            }
        });

        Ok(())
    }

    /// Send a message to the server.
    pub async fn send(&self, msg: WsMessage) -> Result<(), String> {
        let json = serde_json::to_string(&msg).map_err(|e| format!("Serialize error: {}", e))?;
        if let Some(sender) = &self.sender {
            sender
                .send(json)
                .await
                .map_err(|e| format!("Send error: {}", e))
        } else {
            Err("WebSocket not connected".to_string())
        }
    }

    /// Disconnect from the WebSocket server.
    pub async fn disconnect(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(()).await;
        }
        self.sender = None;
        *self.status.write().await = WsStatus::Disconnected;
    }
}
