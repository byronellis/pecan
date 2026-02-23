use crate::Tool;
use async_trait::async_trait;
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

pub struct ReadFile;

#[async_trait]
impl Tool for ReadFile {
    fn name(&self) -> &str { "read_file" }
    fn description(&self) -> &str { "Reads the content of a file." }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "Path to the file." }
            },
            "required": ["path"]
        })
    }
    async fn call(&self, arguments: Value) -> anyhow::Result<Value> {
        let path = arguments["path"].as_str().ok_or_else(|| anyhow::anyhow!("Missing path"))?;
        let content = fs::read_to_string(path)?;
        Ok(json!({ "content": content }))
    }
}

pub struct WriteFile;

#[async_trait]
impl Tool for WriteFile {
    fn name(&self) -> &str { "write_file" }
    fn description(&self) -> &str { "Writes content to a file." }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "Path to the file." },
                "content": { "type": "string", "description": "Content to write." }
            },
            "required": ["path", "content"]
        })
    }
    async fn call(&self, arguments: Value) -> anyhow::Result<Value> {
        let path = arguments["path"].as_str().ok_or_else(|| anyhow::anyhow!("Missing path"))?;
        let content = arguments["content"].as_str().ok_or_else(|| anyhow::anyhow!("Missing content"))?;
        fs::write(path, content)?;
        Ok(json!({ "status": "success" }))
    }
}

pub struct ListDir;

#[async_trait]
impl Tool for ListDir {
    fn name(&self) -> &str { "list_dir" }
    fn description(&self) -> &str { "Lists files in a directory." }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "Path to the directory." }
            },
            "required": ["path"]
        })
    }
    async fn call(&self, arguments: Value) -> anyhow::Result<Value> {
        let path = arguments["path"].as_str().ok_or_else(|| anyhow::anyhow!("Missing path"))?;
        let mut entries = Vec::new();
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().to_string();
            let is_dir = entry.file_type()?.is_dir();
            entries.push(json!({ "name": name, "is_dir": is_dir }));
        }
        Ok(json!({ "entries": entries }))
    }
}

pub struct SpawnSubagent {
    // We'd need a way to communicate back to the server's session manager or provider factory
    // For now, let's keep it abstract
}

#[async_trait]
impl Tool for SpawnSubagent {
    fn name(&self) -> &str { "spawn_subagent" }
    fn description(&self) -> &str { "Spawns a new subagent to handle a subtask." }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "task": { "type": "string", "description": "The task for the subagent to perform." }
            },
            "required": ["task"]
        })
    }
    async fn call(&self, arguments: Value) -> anyhow::Result<Value> {
        let _task = arguments["task"].as_str().ok_or_else(|| anyhow::anyhow!("Missing task"))?;
        // Simplified: just return a mock response for now
        Ok(json!({ "status": "subagent_spawned", "note": "This is a placeholder for real subagent spawning via the server." }))
    }
}
