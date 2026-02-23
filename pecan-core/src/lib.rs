pub mod tools;
pub mod memory;
pub mod config;

use pecan_providers::{Message, Provider, ChatCompletionRequest, Role, LlamaCppProvider, MockProvider};
use crate::memory::MemoryManager;
use crate::config::{Config};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::Mutex;
use std::collections::HashMap;

#[async_trait::async_trait]
pub trait Tool: Send + Sync {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
    fn parameters(&self) -> serde_json::Value;
    async fn call(&self, arguments: serde_json::Value) -> Result<serde_json::Value>;
}

pub struct ToolRegistry {
    pub tools: HashMap<String, Arc<dyn Tool>>,
}

impl ToolRegistry {
    pub fn new() -> Self {
        Self {
            tools: HashMap::new(),
        }
    }

    pub fn register(&mut self, tool: Arc<dyn Tool>) {
        self.tools.insert(tool.name().to_string(), tool);
    }

    pub fn get_definitions(&self) -> Vec<serde_json::Value> {
        self.tools.values().map(|t| {
            serde_json::json!({
                "type": "function",
                "function": {
                    "name": t.name(),
                    "description": t.description(),
                    "parameters": t.parameters(),
                }
            })
        }).collect()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentState {
    pub history: Vec<Message>,
}

pub struct Agent {
    pub provider: Arc<Mutex<Arc<dyn Provider>>>,
    pub state: Arc<Mutex<AgentState>>,
    pub tools: Arc<Mutex<ToolRegistry>>,
    pub memory: Arc<Mutex<MemoryManager>>,
    pub config: Arc<Mutex<Config>>,
}

impl Agent {
    pub async fn new(config: Config, memory_path: &str) -> Result<Self> {
        let provider: Arc<dyn Provider> = Self::create_provider(&config, &config.default_model)?;
        
        Ok(Self {
            provider: Arc::new(Mutex::new(provider)),
            state: Arc::new(Mutex::new(AgentState { history: Vec::new() })),
            tools: Arc::new(Mutex::new(ToolRegistry::new())),
            memory: Arc::new(Mutex::new(MemoryManager::new(memory_path)?)),
            config: Arc::new(Mutex::new(config)),
        })
    }

    fn create_provider(config: &Config, model_name: &str) -> Result<Arc<dyn Provider>> {
        let model = config.models.get(model_name)
            .ok_or_else(|| anyhow::anyhow!("Model {} not found in config", model_name))?;
        
        match model.provider.as_str() {
            "llama.cpp" => Ok(Arc::new(LlamaCppProvider { url: model.url.clone() })),
            "openai" => Ok(Arc::new(pecan_providers::OpenAiProvider { 
                url: model.url.clone(),
                api_key: model.api_key.clone(),
                model_id: model.model_id.clone().unwrap_or_else(|| "gpt-4o".to_string()),
            })),
            "mock" => Ok(Arc::new(MockProvider)),
            _ => anyhow::bail!("Unknown provider type: {}", model.provider),
        }
    }

    pub async fn switch_model(&self, model_name: &str) -> Result<()> {
        let config_lock = self.config.lock().await;
        let provider = Self::create_provider(&config_lock, model_name)?;
        
        let mut provider_lock = self.provider.lock().await;
        *provider_lock = provider;
        Ok(())
    }

    pub async fn chat(&self, user_input: String) -> Result<String> {
        // 1. Retrieve relevant memories
        let memories = {
            let memory = self.memory.lock().await;
            memory.search(&user_input, 5)?
        };

        {
            let mut state = self.state.lock().await;
            
            // If there are memories, inject them as a system message or similar
            if !memories.is_empty() {
                let mut context = String::from("Relevant past interactions:\n");
                for (content, summary) in memories {
                    context.push_str(&format!("- {}: {}\n", summary, content));
                }
                state.history.push(Message {
                    role: Role::System,
                    content: Some(context),
                    tool_calls: None,
                    tool_call_id: None,
                });
            }

            state.history.push(Message {
                role: Role::User,
                content: Some(user_input.clone()),
                tool_calls: None,
                tool_call_id: None,
            });
        }

        let mut final_response = String::new();

        loop {
            let (messages, tool_definitions) = {
                let state = self.state.lock().await;
                let tools = self.tools.lock().await;
                (state.history.clone(), tools.get_definitions())
            };

            let request = ChatCompletionRequest {
                messages,
                temperature: Some(0.7),
                max_tokens: Some(1024),
                tools: Some(tool_definitions),
            };

            let provider = self.provider.lock().await;
            let response = provider.chat_completion(request).await?;
            drop(provider);
            
            {
                let mut state = self.state.lock().await;
                state.history.push(Message {
                    role: Role::Assistant,
                    content: response.content.clone(),
                    tool_calls: response.tool_calls.clone(),
                    tool_call_id: None,
                });
            }

            if let Some(tool_calls) = response.tool_calls {
                for tool_call in tool_calls {
                    let tool_name = &tool_call.function.name;
                    let arguments: serde_json::Value = serde_json::from_str(&tool_call.function.arguments)?;
                    
                    let result = {
                        let tools = self.tools.lock().await;
                        if let Some(tool) = tools.tools.get(tool_name) {
                            tool.call(arguments).await?
                        } else {
                            serde_json::json!({ "error": format!("Tool {} not found", tool_name) })
                        }
                    };

                    let mut state = self.state.lock().await;
                    state.history.push(Message {
                        role: Role::Tool,
                        content: Some(result.to_string()),
                        tool_calls: None,
                        tool_call_id: Some(tool_call.id),
                    });
                }
                continue;
            }

            final_response = response.content.unwrap_or_default();
            break;
        }

        // 2. Summarize and store the interaction
        let summary = self.summarize_interaction(&user_input, &final_response).await?;
        {
            let mut memory = self.memory.lock().await;
            memory.add_memory(&format!("User: {}\nAssistant: {}", user_input, final_response), &summary)?;
        }

        Ok(final_response)
    }

    async fn summarize_interaction(&self, user_input: &str, assistant_response: &str) -> Result<String> {
        let prompt = format!(
            "Summarize the following interaction in one short sentence for long-term memory:\nUser: {}\nAssistant: {}",
            user_input, assistant_response
        );

        let request = ChatCompletionRequest {
            messages: vec![Message {
                role: Role::User,
                content: Some(prompt),
                tool_calls: None,
                tool_call_id: None,
            }],
            temperature: Some(0.3),
            max_tokens: Some(100),
            tools: None,
        };

        let provider = self.provider.lock().await;
        let response = provider.chat_completion(request).await?;
        Ok(response.content.unwrap_or_else(|| "Interaction summary".to_string()))
    }
}
