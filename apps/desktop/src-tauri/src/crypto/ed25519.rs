use base64::{engine::general_purpose::STANDARD, Engine as _};
use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};

use super::keystore::KeyStore;

#[derive(Debug, Serialize, Deserialize)]
pub struct KeyPair {
    pub public_key: Vec<u8>,
    pub user_id: Option<String>,
}

pub struct Ed25519Manager;

impl Ed25519Manager {
    pub fn generate_keypair() -> (SigningKey, VerifyingKey) {
        let mut rng = rand::thread_rng();
        let signing_key = SigningKey::generate(&mut rng);
        let verifying_key = signing_key.verifying_key();
        (signing_key, verifying_key)
    }

    pub fn sign_challenge(private_key: &[u8], challenge: &str) -> Result<Vec<u8>, String> {
        let key_bytes: [u8; 32] = private_key
            .try_into()
            .map_err(|_| "Invalid private key length".to_string())?;
        let signing_key = SigningKey::from_bytes(&key_bytes);
        let signature = signing_key.sign(challenge.as_bytes());
        Ok(signature.to_bytes().to_vec())
    }

    pub fn store_private_key(private_key: &[u8]) -> Result<(), String> {
        let encoded = STANDARD.encode(private_key);
        KeyStore::set("ed25519_private_key", &encoded)
    }

    pub fn load_private_key() -> Result<Vec<u8>, String> {
        let encoded = KeyStore::get("ed25519_private_key")?;
        STANDARD
            .decode(&encoded)
            .map_err(|e| format!("Failed to decode private key: {}", e))
    }

    pub fn delete_private_key() -> Result<(), String> {
        KeyStore::delete("ed25519_private_key")
    }

    pub fn public_key_from_private(private_key: &[u8]) -> Result<Vec<u8>, String> {
        let key_bytes: [u8; 32] = private_key
            .try_into()
            .map_err(|_| "Invalid private key length".to_string())?;
        let signing_key = SigningKey::from_bytes(&key_bytes);
        Ok(signing_key.verifying_key().to_bytes().to_vec())
    }
}
