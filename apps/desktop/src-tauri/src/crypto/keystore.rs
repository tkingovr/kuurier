use keyring::Entry;

const SERVICE_NAME: &str = "com.kuurier.desktop";

/// OS keychain abstraction for secure key storage.
/// Uses macOS Keychain, Windows Credential Manager, or Linux libsecret.
pub struct KeyStore;

impl KeyStore {
    /// Store a value in the OS keychain.
    pub fn set(key: &str, value: &str) -> Result<(), String> {
        let entry = Entry::new(SERVICE_NAME, key)
            .map_err(|e| format!("Keychain error: {}", e))?;
        entry
            .set_password(value)
            .map_err(|e| format!("Failed to store key '{}': {}", key, e))
    }

    /// Retrieve a value from the OS keychain.
    pub fn get(key: &str) -> Result<String, String> {
        let entry = Entry::new(SERVICE_NAME, key)
            .map_err(|e| format!("Keychain error: {}", e))?;
        entry
            .get_password()
            .map_err(|e| format!("Failed to get key '{}': {}", key, e))
    }

    /// Delete a value from the OS keychain.
    pub fn delete(key: &str) -> Result<(), String> {
        let entry = Entry::new(SERVICE_NAME, key)
            .map_err(|e| format!("Keychain error: {}", e))?;
        entry
            .delete_credential()
            .map_err(|e| format!("Failed to delete key '{}': {}", key, e))
    }

    /// Store auth token.
    pub fn set_token(token: &str) -> Result<(), String> {
        Self::set("auth_token", token)
    }

    /// Get auth token.
    pub fn get_token() -> Result<String, String> {
        Self::get("auth_token")
    }

    /// Store user ID.
    pub fn set_user_id(user_id: &str) -> Result<(), String> {
        Self::set("user_id", user_id)
    }

    /// Get user ID.
    pub fn get_user_id() -> Result<String, String> {
        Self::get("user_id")
    }

    /// Delete all stored credentials (panic wipe).
    pub fn wipe_all() -> Result<(), String> {
        let keys = [
            "ed25519_private_key",
            "auth_token",
            "user_id",
            "device_id",
            "db_encryption_key",
        ];
        for key in &keys {
            // Ignore errors for keys that don't exist
            let _ = Self::delete(key);
        }
        Ok(())
    }
}
