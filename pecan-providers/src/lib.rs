use async_trait::async_trait;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Role {
    System,
    User,
    Assistant,
    Tool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub role: Role,
    pub content: Option<String>,
    pub tool_calls: Option<Vec<ToolCall>>,
    pub tool_call_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    pub r#type: String,
    pub function: ToolFunction,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolFunction {
    pub name: String,
    pub arguments: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatCompletionRequest {
    pub messages: Vec<Message>,
    pub temperature: Option<f32>,
    pub max_tokens: Option<u32>,
    pub tools: Option<Vec<serde_json::Value>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ChatCompletionResponse {
    pub content: Option<String>,
    pub tool_calls: Option<Vec<ToolCall>>,
}

#[async_trait]
pub trait Provider: Send + Sync {
    async fn chat_completion(&self, request: ChatCompletionRequest) -> anyhow::Result<ChatCompletionResponse>;
    async fn get_embedding(&self, text: &str) -> anyhow::Result<Vec<f32>>;
}

pub struct MockProvider;

#[async_trait]
impl Provider for MockProvider {
    async fn chat_completion(&self, _request: ChatCompletionRequest) -> anyhow::Result<ChatCompletionResponse> {
        Ok(ChatCompletionResponse {
            content: Some("Mock response".to_string()),
            tool_calls: None,
        })
    }
    async fn get_embedding(&self, _text: &str) -> anyhow::Result<Vec<f32>> {
        Ok(vec![0.0; 384])
    }
}

pub struct LlamaCppProvider {
    pub url: String,
}

#[async_trait]
impl Provider for LlamaCppProvider {
    // ... existing implementation ...
    async fn chat_completion(&self, request: ChatCompletionRequest) -> anyhow::Result<ChatCompletionResponse> {
        let client = reqwest::Client::new();
        let base_url = self.url.trim_end_matches('/');
        let endpoint = if base_url.ends_with("/v1") {
            format!("{}/chat/completions", base_url)
        } else {
            format!("{}/v1/chat/completions", base_url)
        };

        let response = client
            .post(endpoint)
            .json(&request)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        let choice = &response["choices"][0];
        let content = choice["message"]["content"].as_str().map(|s| s.to_string());
        
        let tool_calls = choice["message"]["tool_calls"].as_array().map(|calls| {
            calls.iter().filter_map(|call| {
                let id = call["id"].as_str()?.to_string();
                let r#type = call["type"].as_str()?.to_string();
                let name = call["function"]["name"].as_str()?.to_string();
                let arguments = call["function"]["arguments"].as_str()?.to_string();
                Some(ToolCall {
                    id,
                    r#type,
                    function: crate::ToolFunction { name, arguments },
                })
            }).collect()
        });

        Ok(ChatCompletionResponse { content, tool_calls })
    }

    async fn get_embedding(&self, text: &str) -> anyhow::Result<Vec<f32>> {
        let client = reqwest::Client::new();
        let response = client
            .post(format!("{}/embedding", self.url))
            .json(&serde_json::json!({ "content": text }))
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        let embedding = response["embedding"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("Invalid embedding response"))?
            .iter()
            .filter_map(|v| v.as_f64().map(|f| f as f32))
            .collect();

        Ok(embedding)
    }
}

pub struct OpenAiProvider {
    pub url: String,
    pub api_key: Option<String>,
    pub model_id: String,
}

#[async_trait]
impl Provider for OpenAiProvider {
    async fn chat_completion(&self, mut request: ChatCompletionRequest) -> anyhow::Result<ChatCompletionResponse> {
        let client = reqwest::Client::new();
        
        // Ensure the correct model ID is used in the request
        let mut request_json = serde_json::to_value(&request)?;
        request_json["model"] = serde_json::Value::String(self.model_id.clone());

        let base_url = self.url.trim_end_matches('/');
        let endpoint = if base_url.ends_with("/v1") {
            format!("{}/chat/completions", base_url)
        } else {
            format!("{}/v1/chat/completions", base_url)
        };

        let mut rb = client.post(endpoint);
        
        if let Some(key) = &self.api_key {
            rb = rb.header("Authorization", format!("Bearer {}", key));
        }

        let response = rb
            .json(&request_json)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        if let Some(error) = response["error"].as_object() {
            anyhow::bail!("OpenAI Error: {}", error["message"].as_str().unwrap_or("Unknown error"));
        }

        let choice = &response["choices"][0];
        let content = choice["message"]["content"].as_str().map(|s| s.to_string());
        
        let tool_calls = choice["message"]["tool_calls"].as_array().map(|calls| {
            calls.iter().filter_map(|call| {
                let id = call["id"].as_str()?.to_string();
                let r#type = call["type"].as_str()?.to_string();
                let name = call["function"]["name"].as_str()?.to_string();
                let arguments = call["function"]["arguments"].as_str()?.to_string();
                Some(ToolCall {
                    id,
                    r#type,
                    function: crate::ToolFunction { name, arguments },
                })
            }).collect()
        });

        Ok(ChatCompletionResponse { content, tool_calls })
    }

    async fn get_embedding(&self, text: &str) -> anyhow::Result<Vec<f32>> {
        let client = reqwest::Client::new();
        let base_url = self.url.trim_end_matches('/');
        let endpoint = if base_url.ends_with("/v1") {
            format!("{}/embeddings", base_url)
        } else {
            format!("{}/v1/embeddings", base_url)
        };

        let mut rb = client.post(endpoint);
        
        if let Some(key) = &self.api_key {
            rb = rb.header("Authorization", format!("Bearer {}", key));
        }

        let response = rb
            .json(&serde_json::json!({
                "input": text,
                "model": "text-embedding-3-small" // Default or configurable?
            }))
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        let embedding = response["data"][0]["embedding"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("Invalid embedding response: {:?}", response))?
            .iter()
            .filter_map(|v| v.as_f64().map(|f| f as f32))
            .collect();

        Ok(embedding)
    }
}

