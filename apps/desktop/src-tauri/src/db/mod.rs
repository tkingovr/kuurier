use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;

/// Local SQLite database for caching messages, channels, feed, and Signal sessions.
/// Wrapped in a Mutex because rusqlite::Connection is not Sync.
pub struct Database {
    conn: Mutex<Connection>,
}

impl Database {
    pub fn open(path: &PathBuf) -> Result<Self, String> {
        let conn =
            Connection::open(path).map_err(|e| format!("Failed to open database: {}", e))?;
        let db = Self {
            conn: Mutex::new(conn),
        };
        db.initialize()?;
        Ok(db)
    }

    fn initialize(&self) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| format!("Lock: {}", e))?;
        conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS messages_cache (
                id TEXT PRIMARY KEY, channel_id TEXT NOT NULL, sender_id TEXT NOT NULL,
                content TEXT, message_type TEXT, created_at TEXT, updated_at TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_msg_ch ON messages_cache(channel_id);
            CREATE TABLE IF NOT EXISTS channels_cache (
                id TEXT PRIMARY KEY, name TEXT, type TEXT, org_id TEXT,
                last_message TEXT, last_activity TEXT, unread_count INTEGER DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS feed_cache (
                id TEXT PRIMARY KEY, type TEXT, data TEXT, fetched_at TEXT
            );
            CREATE TABLE IF NOT EXISTS signal_sessions (
                address TEXT PRIMARY KEY, session_data BLOB
            );
            CREATE TABLE IF NOT EXISTS app_state (key TEXT PRIMARY KEY, value TEXT);
            ",
        )
        .map_err(|e| format!("Init db: {}", e))?;
        Ok(())
    }

    pub fn cache_message(
        &self,
        id: &str,
        channel_id: &str,
        sender_id: &str,
        content: Option<&str>,
        message_type: &str,
        created_at: &str,
    ) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| format!("Lock: {}", e))?;
        conn.execute(
            "INSERT OR REPLACE INTO messages_cache (id, channel_id, sender_id, content, message_type, created_at) VALUES (?1,?2,?3,?4,?5,?6)",
            params![id, channel_id, sender_id, content, message_type, created_at],
        ).map_err(|e| format!("Cache msg: {}", e))?;
        Ok(())
    }

    pub fn get_cached_messages(
        &self,
        channel_id: &str,
        limit: u32,
    ) -> Result<Vec<CachedMessage>, String> {
        let conn = self.conn.lock().map_err(|e| format!("Lock: {}", e))?;
        let mut stmt = conn
            .prepare("SELECT id, channel_id, sender_id, content, message_type, created_at FROM messages_cache WHERE channel_id = ?1 ORDER BY created_at DESC LIMIT ?2")
            .map_err(|e| format!("Prepare: {}", e))?;
        let rows = stmt
            .query_map(params![channel_id, limit], |row| {
                Ok(CachedMessage {
                    id: row.get(0)?,
                    channel_id: row.get(1)?,
                    sender_id: row.get(2)?,
                    content: row.get(3)?,
                    message_type: row.get(4)?,
                    created_at: row.get(5)?,
                })
            })
            .map_err(|e| format!("Query: {}", e))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("Row: {}", e))
    }

    pub fn wipe(&self) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| format!("Lock: {}", e))?;
        conn.execute_batch(
            "DELETE FROM messages_cache; DELETE FROM channels_cache; DELETE FROM feed_cache; DELETE FROM signal_sessions; DELETE FROM app_state;",
        )
        .map_err(|e| format!("Wipe: {}", e))?;
        Ok(())
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CachedMessage {
    pub id: String,
    pub channel_id: String,
    pub sender_id: String,
    pub content: Option<String>,
    pub message_type: Option<String>,
    pub created_at: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CachedChannel {
    pub id: String,
    pub name: Option<String>,
    pub channel_type: Option<String>,
    pub org_id: Option<String>,
    pub unread_count: Option<i64>,
    pub last_activity: Option<String>,
}
