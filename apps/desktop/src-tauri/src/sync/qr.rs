use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use qrcode::QrCode;
use serde::{Deserialize, Serialize};
use x25519_dalek::{PublicKey, StaticSecret};

use crate::crypto::keystore::KeyStore;

#[derive(Debug, Serialize, Deserialize)]
pub struct QrCodeData {
    pub desktop_pub_key: String,
    pub secret: String,
    pub device_id: String,
    pub qr_image: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct LinkResult {
    pub ed25519_private_key: Vec<u8>,
    pub user_id: String,
    pub token: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct EncryptedLinkPayload {
    pub mobile_pub_key: String,
    pub ciphertext: String,
    pub nonce: String,
}

pub struct DeviceLinker {
    ephemeral_secret: Option<StaticSecret>,
    link_secret: Option<[u8; 32]>,
    device_id: Option<String>,
}

impl DeviceLinker {
    pub fn new() -> Self {
        Self {
            ephemeral_secret: None,
            link_secret: None,
            device_id: None,
        }
    }

    pub fn generate_qr(&mut self) -> Result<QrCodeData, String> {
        let mut rng = rand::thread_rng();

        let secret = StaticSecret::random_from_rng(&mut rng);
        let public = PublicKey::from(&secret);

        let mut link_secret = [0u8; 32];
        rand::RngCore::fill_bytes(&mut rng, &mut link_secret);

        let device_id = uuid::Uuid::new_v4().to_string();

        let qr_data = serde_json::json!({
            "dpk": URL_SAFE_NO_PAD.encode(public.as_bytes()),
            "s": URL_SAFE_NO_PAD.encode(&link_secret),
            "did": &device_id,
        });
        let qr_string =
            serde_json::to_string(&qr_data).map_err(|e| format!("JSON error: {}", e))?;

        let code =
            QrCode::new(qr_string.as_bytes()).map_err(|e| format!("QR error: {}", e))?;
        let image = code
            .render::<qrcode::render::unicode::Dense1x2>()
            .build();

        self.ephemeral_secret = Some(secret);
        self.link_secret = Some(link_secret);
        self.device_id = Some(device_id.clone());

        Ok(QrCodeData {
            desktop_pub_key: URL_SAFE_NO_PAD.encode(public.as_bytes()),
            secret: URL_SAFE_NO_PAD.encode(&link_secret),
            device_id,
            qr_image: image,
        })
    }

    pub fn decrypt_payload(&self, payload: &EncryptedLinkPayload) -> Result<LinkResult, String> {
        let ephemeral_secret = self
            .ephemeral_secret
            .as_ref()
            .ok_or("No active linking session")?;
        let link_secret = self
            .link_secret
            .as_ref()
            .ok_or("No active linking session")?;

        let mobile_pub_bytes = URL_SAFE_NO_PAD
            .decode(&payload.mobile_pub_key)
            .map_err(|e| format!("Decode mobile pub key: {}", e))?;
        let mobile_pub: [u8; 32] = mobile_pub_bytes
            .try_into()
            .map_err(|_| "Invalid mobile public key length")?;
        let mobile_public = PublicKey::from(mobile_pub);

        let shared_secret = ephemeral_secret.diffie_hellman(&mobile_public);

        let hkdf =
            hkdf::Hkdf::<sha2::Sha256>::new(Some(link_secret), shared_secret.as_bytes());
        let mut derived_key = [0u8; 32];
        hkdf.expand(b"KuurierDeviceLink", &mut derived_key)
            .map_err(|e| format!("HKDF error: {}", e))?;

        use aes_gcm::{
            aead::{Aead, KeyInit},
            Aes256Gcm, Nonce,
        };

        let cipher = Aes256Gcm::new_from_slice(&derived_key)
            .map_err(|e| format!("AES key error: {}", e))?;

        let nonce_bytes = URL_SAFE_NO_PAD
            .decode(&payload.nonce)
            .map_err(|e| format!("Decode nonce: {}", e))?;
        let nonce = Nonce::from_slice(&nonce_bytes);

        let ciphertext = URL_SAFE_NO_PAD
            .decode(&payload.ciphertext)
            .map_err(|e| format!("Decode ciphertext: {}", e))?;

        let plaintext = cipher
            .decrypt(nonce, ciphertext.as_ref())
            .map_err(|_| "Decryption failed — invalid QR or tampered payload".to_string())?;

        let link_data: serde_json::Value =
            serde_json::from_slice(&plaintext).map_err(|e| format!("Parse payload: {}", e))?;

        let ed25519_key = URL_SAFE_NO_PAD
            .decode(
                link_data
                    .get("ed25519_private_key")
                    .and_then(|v| v.as_str())
                    .ok_or("Missing ed25519_private_key in payload")?,
            )
            .map_err(|e| format!("Decode ed25519 key: {}", e))?;

        let user_id = link_data
            .get("user_id")
            .and_then(|v| v.as_str())
            .ok_or("Missing user_id in payload")?
            .to_string();

        let token = link_data
            .get("token")
            .and_then(|v| v.as_str())
            .ok_or("Missing token in payload")?
            .to_string();

        crate::crypto::ed25519::Ed25519Manager::store_private_key(&ed25519_key)?;
        KeyStore::set_token(&token)?;
        KeyStore::set_user_id(&user_id)?;

        Ok(LinkResult {
            ed25519_private_key: ed25519_key,
            user_id,
            token,
        })
    }

    pub fn device_id(&self) -> Option<&str> {
        self.device_id.as_deref()
    }
}
