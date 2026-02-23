use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{PathBuf};
use anyhow::Result;
use directories::ProjectDirs;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelDef {
    pub name: String,
    pub provider: String, // "llama.cpp", "mock", "openai", etc.
    pub url: String,
    pub api_key: Option<String>,
    pub model_id: Option<String>,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolConfig {
    pub require_approval: bool,
    pub allowed_shell_commands: Vec<String>,
    pub blocked_shell_commands: Vec<String>,
}

impl Default for ToolConfig {
    fn default() -> Self {
        Self {
            require_approval: true,
            allowed_shell_commands: vec!["ls".to_string(), "cat".to_string(), "grep".to_string(), "pwd".to_string()],
            blocked_shell_commands: vec!["rm".to_string(), "mv".to_string()],
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub default_model: String,
    pub models: HashMap<String, ModelDef>,
    #[serde(default)]
    pub tools: ToolConfig,
}

impl Default for Config {
    fn default() -> Self {
        let mut models = HashMap::new();
        models.insert("mock".to_string(), ModelDef {
            name: "mock".to_string(),
            provider: "mock".to_string(),
            url: "".to_string(),
            api_key: None,
            model_id: None,
            description: Some("Mock model for testing".to_string()),
        });
        
        Self {
            default_model: "mock".to_string(),
            models,
            tools: ToolConfig::default(),
        }
    }
}

impl Config {
    pub fn load() -> Result<Self> {
        let config_path = Self::get_config_path()?;
        if config_path.exists() {
            let content = fs::read_to_string(config_path)?;
            let config: Config = serde_yaml::from_str(&content)?;
            Ok(config)
        } else {
            let config = Config::default();
            config.save()?;
            Ok(config)
        }
    }

    pub fn save(&self) -> Result<()> {
        let config_path = Self::get_config_path()?;
        if let Some(parent) = config_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let content = serde_yaml::to_string(self)?;
        fs::write(config_path, content)?;
        Ok(())
    }

    pub fn get_config_path() -> Result<PathBuf> {
        let home = dirs::home_dir().ok_or_else(|| anyhow::anyhow!("Could not find home directory"))?;
        Ok(home.join(".pecan").join("config.yaml"))
    }
}
