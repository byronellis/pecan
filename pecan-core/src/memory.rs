use serde::{Deserialize, Serialize};
use anyhow::Result;
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, Write};
use std::path::Path;
use rusqlite::{params, Connection};
use chrono::{DateTime, Utc};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum MemoryOp {
    Add {
        id: Uuid,
        content: String,
        summary: String,
        timestamp: DateTime<Utc>,
    },
    Forget {
        id: Uuid,
    },
}

pub struct MemoryManager {
    log_path: String,
    db_conn: Connection,
}

impl MemoryManager {
    pub fn new(base_path: &str) -> Result<Self> {
        let log_path = format!("{}.jsonl", base_path);
        let db_path = format!("{}.db", base_path);

        // Initialize SQLite index
        let mut db_conn = Connection::open(db_path)?;
        Self::setup_db(&mut db_conn)?;

        let mut manager = Self {
            log_path,
            db_conn,
        };

        // Bootstrap: Sync SQLite with log
        manager.sync_index()?;

        Ok(manager)
    }

    fn setup_db(conn: &mut Connection) -> Result<()> {
        // Main metadata table with explicit INTEGER PRIMARY KEY for reliable rowid
        conn.execute(
            "CREATE TABLE IF NOT EXISTS memories (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                content TEXT NOT NULL,
                summary TEXT NOT NULL,
                timestamp TEXT NOT NULL
            )",
            [],
        )?;

        // FTS5 Virtual Table for searching
        conn.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
                content,
                summary,
                content='memories',
                content_rowid='rowid'
            )",
            [],
        )?;

        // Triggers to keep FTS in sync
        conn.execute_batch(
            "CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
                INSERT INTO memories_fts(rowid, content, summary) VALUES (new.rowid, new.content, new.summary);
            END;
            CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
                INSERT INTO memories_fts(memories_fts, rowid, content, summary) VALUES('delete', old.rowid, old.content, old.summary);
            END;
            CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
                INSERT INTO memories_fts(memories_fts, rowid, content, summary) VALUES('delete', old.rowid, old.content, old.summary);
                INSERT INTO memories_fts(rowid, content, summary) VALUES (new.rowid, new.content, new.summary);
            END;"
        )?;

        Ok(())
    }

    fn sync_index(&mut self) -> Result<()> {
        if !Path::new(&self.log_path).exists() {
            return Ok(());
        }

        let tx = self.db_conn.transaction()?;
        
        let file = fs::File::open(&self.log_path)?;
        let reader = io::BufReader::new(file);

        for line in reader.lines() {
            let op: MemoryOp = serde_json::from_str(&line?)?;
            match op {
                MemoryOp::Add { id, content, summary, timestamp } => {
                    tx.execute(
                        "INSERT OR REPLACE INTO memories (id, content, summary, timestamp) VALUES (?, ?, ?, ?)",
                        params![id.to_string(), content, summary, timestamp.to_rfc3339()],
                    )?;
                }
                MemoryOp::Forget { id } => {
                    tx.execute("DELETE FROM memories WHERE id = ?", params![id.to_string()])?;
                }
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn add_memory(&mut self, content: &str, summary: &str) -> Result<Uuid> {
        let id = Uuid::new_v4();
        let timestamp = Utc::now();
        let op = MemoryOp::Add {
            id,
            content: content.to_string(),
            summary: summary.to_string(),
            timestamp,
        };

        // Append to log
        self.append_to_log(&op)?;

        // Update index
        self.db_conn.execute(
            "INSERT INTO memories (id, content, summary, timestamp) VALUES (?, ?, ?, ?)",
            params![id.to_string(), content, summary, timestamp.to_rfc3339()],
        )?;

        Ok(id)
    }

    pub fn forget_memory(&mut self, id: Uuid) -> Result<()> {
        let op = MemoryOp::Forget { id };
        self.append_to_log(&op)?;

        self.db_conn.execute("DELETE FROM memories WHERE id = ?", params![id.to_string()])?;
        Ok(())
    }

    fn append_to_log(&self, op: &MemoryOp) -> Result<()> {
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.log_path)?;
        
        let json = serde_json::to_string(op)?;
        writeln!(file, "{}", json)?;
        Ok(())
    }

    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<(String, String)>> {
        // Sanitize query for FTS5: remove special characters or quote them
        // For simplicity, we'll just wrap the terms in quotes if they aren't already
        let sanitized_query = query
            .split_whitespace()
            .map(|word| format!("\"{}\"", word.replace('\"', "")))
            .collect::<Vec<_>>()
            .join(" ");

        let mut stmt = self.db_conn.prepare(
            "SELECT content, summary FROM memories_fts WHERE memories_fts MATCH ? LIMIT ?"
        )?;
        
        let rows = stmt.query_map(params![sanitized_query, limit], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })?;

        let mut results = Vec::new();
        for row in rows {
            results.push(row?);
        }
        Ok(results)
    }

    pub fn compact(&mut self) -> Result<()> {
        // Read all current memories from the DB (the source of truth for active state)
        let mut stmt = self.db_conn.prepare("SELECT id, content, summary, timestamp FROM memories")?;
        let rows = stmt.query_map([], |row| {
            Ok(MemoryOp::Add {
                id: Uuid::parse_str(&row.get::<_, String>(0)?).unwrap(),
                content: row.get(1)?,
                summary: row.get(2)?,
                timestamp: DateTime::parse_from_rfc3339(&row.get::<_, String>(3)?).unwrap().with_timezone(&Utc),
            })
        })?;

        let temp_log_path = format!("{}.tmp", self.log_path);
        let mut file = fs::File::create(&temp_log_path)?;

        for row in rows {
            let op = row?;
            let json = serde_json::to_string(&op)?;
            writeln!(file, "{}", json)?;
        }

        // Atomically replace the log
        fs::rename(temp_log_path, &self.log_path)?;

        Ok(())
    }
}
