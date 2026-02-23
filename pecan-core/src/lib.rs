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
use uuid::Uuid;
use chrono::{DateTime, Utc};

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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub id: Uuid,
    pub description: String,
    pub status: TaskStatus,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum TaskStatus {
    Pending,
    InProgress,
    Completed,
    Failed(String),
}

pub struct TaskStack {
    pub tasks: Vec<Task>,
}

impl TaskStack {
    pub fn new() -> Self {
        Self { tasks: Vec::new() }
    }

    pub fn push(&mut self, description: String) -> Uuid {
        let id = Uuid::new_v4();
        self.tasks.push(Task {
            id,
            description,
            status: TaskStatus::Pending,
            created_at: Utc::now(),
        });
        id
    }

    pub fn pop(&mut self) -> Option<Task> {
        let idx = self.tasks.iter().position(|t| t.status == TaskStatus::Pending)?;
        Some(self.tasks.remove(idx))
    }

    pub fn cancel_task(&mut self, id: Uuid) {
        if let Some(task) = self.tasks.iter_mut().find(|t| t.id == id) {
            task.status = TaskStatus::Failed("Cancelled by user".to_string());
        }
    }

    pub fn clear_completed(&mut self) {
        self.tasks.retain(|t| matches!(t.status, TaskStatus::Pending | TaskStatus::InProgress));
    }

    pub fn peek(&self) -> Option<&Task> {
        self.tasks.iter().find(|t| t.status == TaskStatus::Pending)
    }

    pub fn update_status(&mut self, id: Uuid, status: TaskStatus) {
        if let Some(task) = self.tasks.iter_mut().find(|t| t.id == id) {
            task.status = status;
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PendingToolCall {
    pub id: String,
    pub tool_name: String,
    pub arguments: serde_json::Value,
}

pub struct Agent {
    pub provider: Arc<Mutex<Arc<dyn Provider>>>,
    pub state: Arc<Mutex<AgentState>>,
    pub tools: Arc<Mutex<ToolRegistry>>,
    pub memory: Arc<Mutex<MemoryManager>>,
    pub config: Arc<Mutex<Config>>,
    pub task_stack: Arc<Mutex<TaskStack>>,
    pub paused: Arc<Mutex<bool>>,
    pub pending_tool_call: Arc<Mutex<Option<PendingToolCall>>>,
}

impl Agent {
    pub async fn new(config: Config, memory_path: &str) -> Result<Self> {
        let provider: Arc<dyn Provider> = Self::create_provider(&config, &config.default_model)?;
        let task_stack = Arc::new(Mutex::new(TaskStack::new()));
        let tools = Arc::new(Mutex::new(ToolRegistry::new()));
        let paused = Arc::new(Mutex::new(false));
        let pending_tool_call = Arc::new(Mutex::new(None));

        {
            let mut registry = tools.lock().await;
            registry.register(Arc::new(tools::ReadFile));
            registry.register(Arc::new(tools::WriteFile));
            registry.register(Arc::new(tools::ListDir));
            registry.register(Arc::new(tools::SpawnSubagent));
            registry.register(Arc::new(tools::PushTask { stack: task_stack.clone() }));
            registry.register(Arc::new(tools::Shell));
        }
        
        Ok(Self {
            provider: Arc::new(Mutex::new(provider)),
            state: Arc::new(Mutex::new(AgentState { history: Vec::new() })),
            tools,
            memory: Arc::new(Mutex::new(MemoryManager::new(memory_path)?)),
            config: Arc::new(Mutex::new(config)),
            task_stack,
            paused,
            pending_tool_call,
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

    fn check_shell_security(config: &Config, arguments: &serde_json::Value) -> Result<()> {
        let command = arguments["command"].as_str().ok_or_else(|| anyhow::anyhow!("Missing command"))?;
        
        if config.tools.blocked_shell_commands.iter().any(|c| command.contains(c)) {
            anyhow::bail!("Command '{}' is explicitly blocked in configuration.", command);
        }

        if !config.tools.allowed_shell_commands.is_empty() && 
           !config.tools.allowed_shell_commands.iter().any(|c| command.contains(c)) {
            anyhow::bail!("Command '{}' is not in the allowed list.", command);
        }

        Ok(())
    }

    pub async fn approve_tool_call(&self) -> Result<String> {
        let pending = {
            let mut p = self.pending_tool_call.lock().await;
            p.take()
        };

        if let Some(p) = pending {
            if p.tool_name == "shell" {
                let config = self.config.lock().await;
                if let Err(e) = Self::check_shell_security(&config, &p.arguments) {
                    return Err(e);
                }
            }

            let result = {
                let tools = self.tools.lock().await;
                if let Some(tool) = tools.tools.get(&p.tool_name) {
                    tool.call(p.arguments).await?
                } else {
                    serde_json::json!({ "error": format!("Tool {} not found", p.tool_name) })
                }
            };

            {
                let mut state = self.state.lock().await;
                state.history.push(Message {
                    role: Role::Tool,
                    content: Some(result.to_string()),
                    tool_calls: None,
                    tool_call_id: Some(p.id),
                });
            }

            self.chat_loop_continue().await
        } else {
            anyhow::bail!("No pending tool call to approve")
        }
    }

    pub async fn reject_tool_call(&self, reason: &str) -> Result<String> {
        let pending = {
            let mut p = self.pending_tool_call.lock().await;
            p.take()
        };

        if let Some(p) = pending {
            {
                let mut state = self.state.lock().await;
                state.history.push(Message {
                    role: Role::Tool,
                    content: Some(serde_json::json!({ "error": "User rejected tool execution", "reason": reason }).to_string()),
                    tool_calls: None,
                    tool_call_id: Some(p.id),
                });
            }

            self.chat_loop_continue().await
        } else {
            anyhow::bail!("No pending tool call to reject")
        }
    }

    async fn chat_loop_continue(&self) -> Result<String> {
        self.chat_internal().await
    }

    pub async fn chat(&self, user_input: String) -> Result<String> {
        let memories = {
            let memory = self.memory.lock().await;
            memory.search(&user_input, 5)?
        };

        {
            let mut state = self.state.lock().await;
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

        self.chat_internal().await
    }

    async fn chat_internal(&self) -> Result<String> {
        let mut final_response = String::new();

        loop {
            let (messages, tool_definitions) = {
                let state = self.state.lock().await;
                let tools = self.tools.lock().await;
                (state.history.clone(), tools.get_definitions())
            };

            tracing::info!("Sending request to model with {} messages", messages.len());

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
                if !tool_calls.is_empty() {
                    let config = self.config.lock().await;
                    let require_approval = config.tools.require_approval;
                    
                    if require_approval {
                        tracing::info!("Tool approval required for {}", tool_calls[0].function.name);
                        let tool_call = &tool_calls[0];
                        let mut p = self.pending_tool_call.lock().await;
                        *p = Some(PendingToolCall {
                            id: tool_call.id.clone(),
                            tool_name: tool_call.function.name.clone(),
                            arguments: serde_json::from_str(&tool_call.function.arguments)?,
                        });
                        
                        return Ok("WAITING_FOR_APPROVAL".to_string());
                    }

                    for tool_call in tool_calls {
                        let tool_name = &tool_call.function.name;
                        let arguments: serde_json::Value = serde_json::from_str(&tool_call.function.arguments)?;
                        
                        tracing::info!("Executing tool: {} with args: {}", tool_name, arguments);

                        if tool_name == "shell" {
                            if let Err(e) = Self::check_shell_security(&config, &arguments) {
                                let mut state = self.state.lock().await;
                                state.history.push(Message {
                                    role: Role::Tool,
                                    content: Some(serde_json::json!({ "error": e.to_string() }).to_string()),
                                    tool_calls: None,
                                    tool_call_id: Some(tool_call.id.clone()),
                                });
                                continue;
                            }
                        }

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
            }

            final_response = response.content.unwrap_or_default();
            tracing::info!("Model returned final response: {}", final_response);
            break;
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

    pub async fn run_autonomous_loop(&self) -> Result<()> {
        loop {
            {
                let paused = self.paused.lock().await;
                if *paused {
                    drop(paused);
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                    continue;
                }
            }

            let next_task = {
                let mut stack = self.task_stack.lock().await;
                stack.pop()
            };

            let task = match next_task {
                Some(t) => t,
                None => break, 
            };

            let prompt = format!(
                "Current Task: {}\n\nExecute the next step for this task using available tools. \
                If the task is finished, explain what you did. \
                If you need to break it down further, you can use the 'push_task' tool.", 
                task.description
            );
            
            let _response = self.chat(prompt).await?;
        }
        Ok(())
    }
}
