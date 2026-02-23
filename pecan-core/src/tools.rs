use crate::Tool;
use async_trait::async_trait;
use serde_json::{json, Value};
use std::fs;

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

pub struct Shell;

#[async_trait]
impl Tool for Shell {
    fn name(&self) -> &str { "shell" }
    fn description(&self) -> &str { "Executes a shell command." }
    fn parameters(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "command": { "type": "string", "description": "The command to execute." },
                "args": { "type": "array", "items": { "type": "string" }, "description": "Arguments for the command." }
            },
            "required": ["command"]
        })
    }
    async fn call(&self, arguments: Value) -> anyhow::Result<Value> {
        let command = arguments["command"].as_str().ok_or_else(|| anyhow::anyhow!("Missing command"))?;
        let args: Vec<String> = arguments["args"].as_array()
            .unwrap_or(&vec![])
            .iter()
            .filter_map(|v| v.as_str().map(|s| s.to_string()))
            .collect();

        let output = std::process::Command::new(command)
            .args(args)
            .output()?;

        Ok(json!({
            "status": if output.status.success() { "success" } else { "error" },
            "stdout": String::from_utf8_lossy(&output.stdout),
            "stderr": String::from_utf8_lossy(&output.stderr),
            "exit_code": output.status.code(),
        }))
    }
}
