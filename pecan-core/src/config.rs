use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
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
pub struct Config {
    pub default_model: String,
    pub models: HashMap<String, ModelDef>,
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
        if let Some(proj_dirs) = ProjectDirs::from("com", "pecan", "pecan") {
            // Using standard project dirs (~/Library/Application Support/com.pecan.pecan on macOS)
            // But user asked for ~/.pecan/config.yaml specifically
            let home = dirs::home_dir().ok_or_else(|| anyhow::anyhow!("Could not find home directory"))?;
            Ok(home.join(".pecan").join("config.yaml"))
        } else {
            anyhow::bail!("Could not determine configuration directory")
        }
    }
}
