use serde::{Deserialize, Serialize};

/// Signal Protocol key bundle for X3DH key agreement.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyBundle {
    pub identity_key: Vec<u8>,
    pub registration_id: u32,
    pub signed_prekey: SignedPreKey,
    pub prekeys: Vec<PreKey>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignedPreKey {
    pub key_id: u32,
    pub public_key: Vec<u8>,
    pub signature: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PreKey {
    pub key_id: u32,
    pub public_key: Vec<u8>,
}

/// Signal Protocol session manager.
///
/// This module will handle:
/// - X3DH key agreement for session establishment
/// - Double Ratchet for forward-secret message encryption
/// - Sender Keys for group messaging
///
/// For now, this is a placeholder that defines the data structures.
/// The full implementation will use the `libsignal-protocol` crate
/// or a pure Rust implementation of the Signal Protocol.
pub struct SignalManager;

impl SignalManager {
    /// Generate a new identity key pair and registration ID.
    pub fn generate_identity() -> Result<KeyBundle, String> {
        let mut rng = rand::thread_rng();
        let registration_id: u32 = rand::Rng::gen_range(&mut rng, 1..16380);

        // Generate Curve25519 identity key
        let identity_secret = x25519_dalek::StaticSecret::random_from_rng(&mut rng);
        let identity_public = x25519_dalek::PublicKey::from(&identity_secret);

        // Generate signed pre-key
        let spk_secret = x25519_dalek::StaticSecret::random_from_rng(&mut rng);
        let spk_public = x25519_dalek::PublicKey::from(&spk_secret);

        // Sign the pre-key with Ed25519 identity
        let ed_signing_key = ed25519_dalek::SigningKey::generate(&mut rng);
        let signature = ed25519_dalek::Signer::sign(&ed_signing_key, spk_public.as_bytes());

        Ok(KeyBundle {
            identity_key: identity_public.as_bytes().to_vec(),
            registration_id,
            signed_prekey: SignedPreKey {
                key_id: 1,
                public_key: spk_public.as_bytes().to_vec(),
                signature: signature.to_bytes().to_vec(),
            },
            prekeys: Self::generate_prekeys(100)?,
        })
    }

    /// Generate a batch of one-time pre-keys.
    pub fn generate_prekeys(count: u32) -> Result<Vec<PreKey>, String> {
        let mut rng = rand::thread_rng();
        let mut prekeys = Vec::with_capacity(count as usize);

        for i in 1..=count {
            let secret = x25519_dalek::StaticSecret::random_from_rng(&mut rng);
            let public = x25519_dalek::PublicKey::from(&secret);
            prekeys.push(PreKey {
                key_id: i,
                public_key: public.as_bytes().to_vec(),
            });
        }

        Ok(prekeys)
    }
}
