use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// HTTP client that routes all requests through the Tor SOCKS5 proxy.
pub struct ApiClient {
    client: Client,
    base_url: String,
    token: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ApiError {
    pub error: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AuthRegisterRequest {
    pub public_key: String,
    pub invite_code: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AuthRegisterResponse {
    pub user_id: String,
    pub challenge: String,
    pub challenge_mac: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AuthVerifyRequest {
    pub user_id: String,
    pub challenge: String,
    pub signature: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AuthVerifyResponse {
    pub token: String,
    pub user_id: String,
    pub trust_score: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Channel {
    pub id: String,
    pub name: Option<String>,
    #[serde(rename = "type")]
    pub channel_type: String,
    pub org_id: Option<String>,
    pub created_at: String,
    pub unread_count: Option<i64>,
    pub last_message: Option<Value>,
    pub members: Option<Vec<Value>>,
    pub other_user_id: Option<String>,
    pub other_user_display_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub id: String,
    pub channel_id: String,
    pub sender_id: String,
    pub sender_display_name: Option<String>,
    pub ciphertext: Option<String>,
    pub content: Option<String>,
    pub message_type: String,
    pub reply_to_id: Option<String>,
    pub created_at: String,
    pub updated_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Post {
    pub id: String,
    pub user_id: String,
    pub content: String,
    pub source_type: String,
    pub verification_score: Option<f64>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub id: String,
    pub title: String,
    pub description: Option<String>,
    pub starts_at: String,
    pub ends_at: Option<String>,
    pub location_visibility: String,
    pub channel_id: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Alert {
    pub id: String,
    pub user_id: String,
    pub alert_type: String,
    pub description: String,
    pub severity: i32,
    pub status: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserProfile {
    pub id: String,
    pub trust_score: i32,
    pub is_verified: bool,
    pub created_at: String,
    pub display_name: Option<String>,
}

impl ApiClient {
    /// Create a new API client, optionally routing through a SOCKS5 proxy.
    pub fn new(base_url: &str, proxy_url: Option<&str>) -> Result<Self, String> {
        let mut builder = Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .user_agent("Kuurier-Desktop/0.1.0");

        if let Some(proxy) = proxy_url {
            let proxy = reqwest::Proxy::all(proxy)
                .map_err(|e| format!("Invalid proxy URL: {}", e))?;
            builder = builder.proxy(proxy);
        }

        let client = builder
            .build()
            .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

        Ok(Self {
            client,
            base_url: base_url.to_string(),
            token: None,
        })
    }

    /// Set the authentication token.
    pub fn set_token(&mut self, token: String) {
        self.token = Some(token);
    }

    /// Make a GET request.
    pub async fn get(&self, path: &str) -> Result<Value, String> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.client.get(&url);

        if let Some(token) = &self.token {
            req = req.bearer_auth(token);
        }

        let resp = req.send().await.map_err(|e| format!("Request failed: {}", e))?;
        let status = resp.status();
        let body: Value = resp.json().await.map_err(|e| format!("Parse error: {}", e))?;

        if !status.is_success() {
            let msg = body.get("error").and_then(|e| e.as_str()).unwrap_or("Unknown error");
            return Err(format!("API error {}: {}", status.as_u16(), msg));
        }

        Ok(body)
    }

    /// Make a POST request with JSON body.
    pub async fn post(&self, path: &str, body: &Value) -> Result<Value, String> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.client.post(&url).json(body);

        if let Some(token) = &self.token {
            req = req.bearer_auth(token);
        }

        let resp = req.send().await.map_err(|e| format!("Request failed: {}", e))?;
        let status = resp.status();
        let response_body: Value = resp.json().await.map_err(|e| format!("Parse error: {}", e))?;

        if !status.is_success() {
            let msg = response_body.get("error").and_then(|e| e.as_str()).unwrap_or("Unknown error");
            return Err(format!("API error {}: {}", status.as_u16(), msg));
        }

        Ok(response_body)
    }

    /// Make a PUT request with JSON body.
    pub async fn put(&self, path: &str, body: &Value) -> Result<Value, String> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.client.put(&url).json(body);

        if let Some(token) = &self.token {
            req = req.bearer_auth(token);
        }

        let resp = req.send().await.map_err(|e| format!("Request failed: {}", e))?;
        let status = resp.status();
        let response_body: Value = resp.json().await.map_err(|e| format!("Parse error: {}", e))?;

        if !status.is_success() {
            let msg = response_body.get("error").and_then(|e| e.as_str()).unwrap_or("Unknown error");
            return Err(format!("API error {}: {}", status.as_u16(), msg));
        }

        Ok(response_body)
    }

    /// Make a DELETE request.
    pub async fn delete(&self, path: &str) -> Result<Value, String> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.client.delete(&url);

        if let Some(token) = &self.token {
            req = req.bearer_auth(token);
        }

        let resp = req.send().await.map_err(|e| format!("Request failed: {}", e))?;
        let status = resp.status();
        let response_body: Value = resp.json().await.map_err(|e| format!("Parse error: {}", e))?;

        if !status.is_success() {
            let msg = response_body.get("error").and_then(|e| e.as_str()).unwrap_or("Unknown error");
            return Err(format!("API error {}: {}", status.as_u16(), msg));
        }

        Ok(response_body)
    }

    // ---- Auth endpoints ----

    pub async fn auth_register(&self, public_key: &str, invite_code: &str) -> Result<AuthRegisterResponse, String> {
        let body = serde_json::json!({
            "public_key": public_key,
            "invite_code": invite_code,
        });
        let resp = self.post("/auth/register", &body).await?;
        serde_json::from_value(resp).map_err(|e| format!("Parse error: {}", e))
    }

    pub async fn auth_verify(&self, user_id: &str, challenge: &str, signature: &str) -> Result<AuthVerifyResponse, String> {
        let body = serde_json::json!({
            "user_id": user_id,
            "challenge": challenge,
            "signature": signature,
        });
        let resp = self.post("/auth/verify", &body).await?;
        serde_json::from_value(resp).map_err(|e| format!("Parse error: {}", e))
    }

    pub async fn get_me(&self) -> Result<UserProfile, String> {
        let resp = self.get("/me").await?;
        serde_json::from_value(resp).map_err(|e| format!("Parse error: {}", e))
    }

    pub async fn set_display_name(&self, name: &str) -> Result<Value, String> {
        let body = serde_json::json!({ "display_name": name });
        self.put("/me/display-name", &body).await
    }

    // ---- Feed endpoints ----

    pub async fn fetch_feed(&self, feed_type: &str, offset: u32) -> Result<Value, String> {
        self.get(&format!("/feed/v2?feed_type={}&offset={}", feed_type, offset)).await
    }

    pub async fn create_post(&self, content: &str, source_type: &str) -> Result<Value, String> {
        let body = serde_json::json!({
            "content": content,
            "source_type": source_type,
        });
        self.post("/feed/posts", &body).await
    }

    // ---- Messaging endpoints ----

    pub async fn list_channels(&self) -> Result<Vec<Channel>, String> {
        let resp = self.get("/channels").await?;
        let channels = resp.get("channels").cloned().unwrap_or(Value::Array(vec![]));
        serde_json::from_value(channels).map_err(|e| format!("Parse error: {}", e))
    }

    pub async fn get_messages(&self, channel_id: &str, before: Option<&str>) -> Result<Vec<Message>, String> {
        let path = match before {
            Some(b) => format!("/messages/{}?before={}", channel_id, b),
            None => format!("/messages/{}", channel_id),
        };
        let resp = self.get(&path).await?;
        let messages = resp.get("messages").cloned().unwrap_or(Value::Array(vec![]));
        serde_json::from_value(messages).map_err(|e| format!("Parse error: {}", e))
    }

    pub async fn send_message(&self, channel_id: &str, ciphertext: &str) -> Result<Value, String> {
        let body = serde_json::json!({
            "channel_id": channel_id,
            "ciphertext": ciphertext,
            "message_type": "text",
        });
        self.post("/messages", &body).await
    }

    pub async fn create_dm(&self, user_id: &str) -> Result<Channel, String> {
        let body = serde_json::json!({ "user_id": user_id });
        let resp = self.post("/channels/dm", &body).await?;
        serde_json::from_value(resp).map_err(|e| format!("Parse error: {}", e))
    }

    // ---- Events endpoints ----

    pub async fn list_events(&self) -> Result<Value, String> {
        self.get("/events").await
    }

    pub async fn create_event(&self, event: &Value) -> Result<Value, String> {
        self.post("/events", event).await
    }

    // ---- Alerts endpoints ----

    pub async fn list_alerts(&self) -> Result<Value, String> {
        self.get("/alerts").await
    }

    pub async fn create_alert(&self, alert: &Value) -> Result<Value, String> {
        self.post("/alerts", alert).await
    }

    // ---- Device linking endpoints ----

    pub async fn submit_device_link(&self, device_id: &str, encrypted_payload: &str) -> Result<Value, String> {
        let body = serde_json::json!({
            "device_id": device_id,
            "encrypted_payload": encrypted_payload,
        });
        self.post("/devices/link", &body).await
    }

    pub async fn poll_device_link(&self, device_id: &str) -> Result<Value, String> {
        self.get(&format!("/devices/link/{}", device_id)).await
    }

    pub async fn register_device(&self, device_type: &str, device_name: &str) -> Result<Value, String> {
        let body = serde_json::json!({
            "device_type": device_type,
            "device_name": device_name,
        });
        self.post("/devices/register", &body).await
    }
}
