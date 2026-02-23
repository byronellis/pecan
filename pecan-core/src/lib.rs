pub mod tools;
pub mod memory;
pub mod config;

use pecan_providers::{Message, Provider, ChatCompletionRequest, Role, LlamaCppProvider, MockProvider};
use crate::memory::MemoryManager;
use crate::config::Config;
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::sync::{Arc, OnceLock, Mutex as SyncMutex};
use tokio::sync::Mutex;
use std::collections::{HashMap, HashSet};

pub static LOG_BUFFER: OnceLock<Arc<SyncMutex<Vec<String>>>> = OnceLock::new();
pub fn get_log_buffer() -> Arc<SyncMutex<Vec<String>>> {
    LOG_BUFFER.get_or_init(|| Arc::new(SyncMutex::new(Vec::new()))).clone()
}

pub struct TuiLogger;
impl<S: tracing::Subscriber> tracing_subscriber::Layer<S> for TuiLogger {
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: tracing_subscriber::layer::Context<'_, S>) {
        if let Ok(mut buffer) = get_log_buffer().lock() {
            let mut visitor = LogVisitor(String::new());
            event.record(&mut visitor);
            buffer.push(format!("{}: {}", event.metadata().level(), visitor.0));
            if buffer.len() > 1000 { buffer.remove(0); }
        }
    }
}
struct LogVisitor(String);
impl tracing::field::Visit for LogVisitor {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" { self.0 = format!("{:?}", value); }
    }
}

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
    pub fn get_definitions(&self) -> Vec<serde_json::Value> {
        self.tools.values().map(|t| {
            serde_json::json!({
                "type": "function",
                "function": { "name": t.name(), "description": t.description(), "parameters": t.parameters() }
            })
        }).collect()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PendingToolCall {
    pub id: String,
    pub name: String,
    pub args: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum AgentStatus {
    Idle,
    Thinking,
    WaitingForApproval(PendingToolCall),
    Error(String),
}

#[derive(Clone)]
pub struct Agent {
    pub provider: Arc<Mutex<Arc<dyn Provider>>>,
    pub history: Arc<Mutex<Vec<Message>>>,
    pub tools: Arc<Mutex<ToolRegistry>>,
    pub config: Arc<Mutex<Config>>,
    pub status: Arc<Mutex<AgentStatus>>,
    pub session_approved_tools: Arc<Mutex<HashSet<String>>>,
    pub build_info: String,
}

impl Agent {
    pub async fn new(config: Config, _memory_path: &str) -> Result<Self> {
        let provider: Arc<dyn Provider> = match config.models.get(&config.default_model) {
            Some(m) if m.provider == "openai" => Arc::new(pecan_providers::OpenAiProvider {
                url: m.url.clone(), api_key: m.api_key.clone(), model_id: m.model_id.clone().unwrap_or_default(),
            }),
            Some(m) if m.provider == "llama.cpp" => Arc::new(LlamaCppProvider { url: m.url.clone() }),
            _ => Arc::new(MockProvider),
        };

        let mut registry = ToolRegistry { tools: HashMap::new() };
        registry.tools.insert("read_file".to_string(), Arc::new(tools::ReadFile));
        registry.tools.insert("write_file".to_string(), Arc::new(tools::WriteFile));
        registry.tools.insert("list_dir".to_string(), Arc::new(tools::ListDir));
        registry.tools.insert("shell".to_string(), Arc::new(tools::Shell));

        Ok(Self {
            provider: Arc::new(Mutex::new(provider)),
            history: Arc::new(Mutex::new(vec![Message {
                role: Role::System,
                content: Some("You are Pecan, a helpful AI assistant. You use tools to accomplish tasks.".to_string()),
                tool_calls: None, tool_call_id: None,
            }])),
            tools: Arc::new(Mutex::new(registry)),
            config: Arc::new(Mutex::new(config)),
            status: Arc::new(Mutex::new(AgentStatus::Idle)),
            session_approved_tools: Arc::new(Mutex::new(HashSet::new())),
            build_info: format!("v0.1.0-{}", chrono::Utc::now().format("%H:%M:%S")),
        })
    }

    pub async fn step(&self) -> Result<()> {
        loop {
            let (messages, tool_defs) = {
                let h = self.history.lock().await;
                let t = self.tools.lock().await;
                
                // Construct validated history for the provider
                let mut filtered = Vec::new();
                for (i, m) in h.iter().enumerate() {
                    match m.role {
                        Role::Assistant => {
                            let content = m.content.as_ref().filter(|s| !s.is_empty()).cloned();
                            let calls = m.tool_calls.as_ref().filter(|c| !c.is_empty()).cloned();
                            
                            if content.is_some() || calls.is_some() {
                                // If there are tool calls, we MUST check if they are all satisfied
                                if let Some(calls_list) = &calls {
                                    let mut satisfied = true;
                                    for call in calls_list {
                                        let has_result = h.iter().skip(i + 1).any(|rm| rm.role == Role::Tool && rm.tool_call_id.as_deref() == Some(&call.id));
                                        if !has_result {
                                            satisfied = false;
                                            break;
                                        }
                                    }
                                    
                                    // If NOT all tool calls are satisfied, and this is the LAST assistant message,
                                    // we should not call the model yet.
                                    if !satisfied && i == h.iter().rposition(|rm| rm.role == Role::Assistant).unwrap() {
                                        tracing::info!("Waiting for tool results for call: {:?}", calls_list);
                                        return Ok(());
                                    }
                                }

                                filtered.push(Message {
                                    role: Role::Assistant,
                                    content,
                                    tool_calls: calls,
                                    tool_call_id: None,
                                });
                            }
                        }
                        Role::Tool => {
                            // Ensure tool messages have a valid content (even if empty string)
                            filtered.push(Message {
                                role: Role::Tool,
                                content: Some(m.content.clone().unwrap_or_else(|| "".to_string())),
                                tool_calls: None,
                                tool_call_id: m.tool_call_id.clone(),
                            });
                        }
                        _ => filtered.push(m.clone()),
                    }
                }
                (filtered, t.get_definitions())
            };

            tracing::info!("Stepping with {} validated messages", messages.len());
            *self.status.lock().await = AgentStatus::Thinking;

            let request = ChatCompletionRequest {
                messages,
                temperature: Some(0.7),
                max_tokens: Some(1024),
                tools: if tool_defs.is_empty() { None } else { Some(tool_defs) },
            };

            let provider = self.provider.lock().await.clone();
            let response = match provider.chat_completion(request).await {
                Ok(res) => res,
                Err(e) => {
                    tracing::error!("Provider error: {}", e);
                    *self.status.lock().await = AgentStatus::Error(e.to_string());
                    return Err(e);
                }
            };

            let content = response.content.as_ref().filter(|s| !s.is_empty()).cloned();
            let has_tool_calls = response.tool_calls.as_ref().map(|c| !c.is_empty()).unwrap_or(false);

            if content.is_some() || has_tool_calls {
                self.history.lock().await.push(Message {
                    role: Role::Assistant,
                    content,
                    tool_calls: response.tool_calls.clone(),
                    tool_call_id: None,
                });
            } else {
                *self.status.lock().await = AgentStatus::Idle;
                return Ok(());
            }

            if let Some(calls) = response.tool_calls {
                if calls.is_empty() {
                    *self.status.lock().await = AgentStatus::Idle;
                    return Ok(());
                }

                let require_app = self.config.lock().await.tools.require_approval;
                let approved_tools = self.session_approved_tools.lock().await.clone();

                for call in calls {
                    let args = serde_json::from_str(&call.function.arguments).unwrap_or_default();
                    let pending = PendingToolCall { id: call.id.clone(), name: call.function.name.clone(), args };

                    if require_app && !approved_tools.contains(&pending.name) {
                        tracing::info!("Tool {} requires approval", pending.name);
                        *self.status.lock().await = AgentStatus::WaitingForApproval(pending);
                        return Ok(()); 
                    }

                    let result = self.run_tool(pending.clone()).await?;
                    self.history.lock().await.push(Message {
                        role: Role::Tool,
                        content: Some(result),
                        tool_calls: None,
                        tool_call_id: Some(call.id),
                    });
                }
                continue;
            }

            *self.status.lock().await = AgentStatus::Idle;
            return Ok(());
        }
    }

    async fn run_tool(&self, call: PendingToolCall) -> Result<String> {
        tracing::info!("Executing tool: {}", call.name);
        let tool = self.tools.lock().await.tools.get(&call.name).cloned();
        let result = if let Some(t) = tool {
            match t.call(call.args).await {
                Ok(res) => res.to_string(),
                Err(e) => {
                    tracing::error!("Tool error: {}", e);
                    serde_json::json!({ "error": e.to_string() }).to_string()
                }
            }
        } else {
            serde_json::json!({ "error": "Tool not found" }).to_string()
        };
        Ok(result)
    }

    pub async fn execute_tool(&self, call: PendingToolCall) -> Result<()> {
        let result = self.run_tool(call.clone()).await?;
        self.history.lock().await.push(Message {
            role: Role::Tool,
            content: Some(result),
            tool_calls: None,
            tool_call_id: Some(call.id),
        });
        
        let more_pending = {
            let h = self.history.lock().await;
            if let Some(last_assistant_idx) = h.iter().rposition(|m| m.role == Role::Assistant && m.tool_calls.is_some()) {
                let last_assistant = &h[last_assistant_idx];
                let calls = last_assistant.tool_calls.as_ref().unwrap();
                
                let mut next_call = None;
                for call in calls {
                    let has_result = h.iter().skip(last_assistant_idx + 1).any(|m| m.role == Role::Tool && m.tool_call_id.as_deref() == Some(&call.id));
                    if !has_result {
                        let args = serde_json::from_str(&call.function.arguments).unwrap_or_default();
                        next_call = Some(PendingToolCall { id: call.id.clone(), name: call.function.name.clone(), args });
                        break;
                    }
                }
                next_call
            } else {
                None
            }
        };

        if let Some(next) = more_pending {
            let require_app = self.config.lock().await.tools.require_approval;
            let approved_tools = self.session_approved_tools.lock().await.clone();

            if require_app && !approved_tools.contains(&next.name) {
                *self.status.lock().await = AgentStatus::WaitingForApproval(next);
                return Ok(());
            } else {
                return Box::pin(self.execute_tool(next)).await;
            }
        }

        self.step().await
    }

    pub async fn add_user_message(&self, content: String) -> Result<()> {
        self.history.lock().await.push(Message {
            role: Role::User,
            content: Some(content),
            tool_calls: None,
            tool_call_id: None,
        });
        self.step().await
    }

    pub async fn switch_model(&self, model_name: &str) -> Result<()> {
        let config_lock = self.config.lock().await;
        let model = config_lock.models.get(model_name)
            .ok_or_else(|| anyhow::anyhow!("Model {} not found", model_name))?;

        let provider: Arc<dyn Provider> = match model.provider.as_str() {
            "openai" => Arc::new(pecan_providers::OpenAiProvider {
                url: model.url.clone(), api_key: model.api_key.clone(), model_id: model.model_id.clone().unwrap_or_default(),
            }),
            "llama.cpp" => Arc::new(LlamaCppProvider { url: model.url.clone() }),
            _ => Arc::new(MockProvider),
        };

        let mut provider_lock = self.provider.lock().await;
        *provider_lock = provider;
        Ok(())
    }
}
