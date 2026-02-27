use serde::{Deserialize, Serialize};

/// Tor proxy status exposed to the frontend.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "status", content = "detail")]
pub enum TorStatus {
    Disabled,
    Connecting,
    Bootstrapping(u8),
    Connected,
    Error(String),
}

/// Manages the embedded Tor SOCKS5 proxy.
///
/// In development mode, Tor is disabled by default and API calls go direct.
/// When enabled, all traffic routes through the local SOCKS5 proxy.
///
/// Production will use the `arti` crate for an embedded Tor client.
/// For now, we support connecting through an external Tor SOCKS5 proxy
/// (e.g., Tor Browser's proxy on port 9150).
pub struct TorProxy {
    pub status: TorStatus,
    pub socks_port: u16,
    pub enabled: bool,
}

impl TorProxy {
    pub fn new() -> Self {
        Self {
            status: TorStatus::Disabled,
            socks_port: 9150,
            enabled: false,
        }
    }

    /// Start the Tor proxy connection.
    pub async fn start(&mut self) -> Result<(), String> {
        if !self.enabled {
            self.status = TorStatus::Disabled;
            return Ok(());
        }

        self.status = TorStatus::Connecting;

        // Test if the SOCKS5 proxy is reachable
        match tokio::net::TcpStream::connect(format!("127.0.0.1:{}", self.socks_port)).await {
            Ok(_) => {
                self.status = TorStatus::Connected;
                log::info!("Connected to Tor SOCKS5 proxy on port {}", self.socks_port);
                Ok(())
            }
            Err(e) => {
                let msg = format!("Failed to connect to Tor proxy: {}", e);
                self.status = TorStatus::Error(msg.clone());
                log::warn!("{}", msg);
                Err(msg)
            }
        }
    }

    /// Stop the Tor proxy.
    pub async fn stop(&mut self) {
        self.status = TorStatus::Disabled;
        self.enabled = false;
    }

    /// Set whether Tor is enabled.
    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        if !enabled {
            self.status = TorStatus::Disabled;
        }
    }

    /// Get the SOCKS5 proxy URL if Tor is connected.
    pub fn proxy_url(&self) -> Option<String> {
        if self.status == TorStatus::Connected {
            Some(format!("socks5h://127.0.0.1:{}", self.socks_port))
        } else {
            None
        }
    }
}
