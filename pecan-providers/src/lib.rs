use async_trait::async_trait;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
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
    async fn tokenize(&self, text: &str) -> anyhow::Result<Vec<u32>>;
    async fn detokenize(&self, tokens: Vec<u32>) -> anyhow::Result<String>;
    async fn list_models(&self) -> anyhow::Result<Vec<String>>;
    async fn health_check(&self) -> anyhow::Result<bool>;
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
    async fn tokenize(&self, text: &str) -> anyhow::Result<Vec<u32>> {
        Ok(text.split_whitespace().enumerate().map(|(i, _)| i as u32).collect())
    }
    async fn detokenize(&self, tokens: Vec<u32>) -> anyhow::Result<String> {
        Ok(format!("Detokenized {} tokens", tokens.len()))
    }
    async fn list_models(&self) -> anyhow::Result<Vec<String>> {
        Ok(vec!["mock-model".to_string()])
    }
    async fn health_check(&self) -> anyhow::Result<bool> {
        Ok(true)
    }
}

pub struct LlamaCppProvider {
    pub url: String,
}

#[async_trait]
impl Provider for LlamaCppProvider {
    async fn chat_completion(&self, request: ChatCompletionRequest) -> anyhow::Result<ChatCompletionResponse> {
        let client = reqwest::Client::new();
        let base_url = self.url.trim_end_matches('/');
        let endpoint = if base_url.ends_with("/v1") {
            format!("{}/chat/completions", base_url)
        } else {
            format!("{}/v1/chat/completions", base_url)
        };

        let response_json = client
            .post(endpoint)
            .json(&request)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        if let Some(error) = response_json.get("error") {
            anyhow::bail!("Server Error: {}", error.get("message").and_then(|m| m.as_str()).unwrap_or("Unknown error"));
        }

        let choice = response_json.get("choices")
            .and_then(|c| c.as_array())
            .and_then(|a| a.get(0))
            .ok_or_else(|| anyhow::anyhow!("No choices returned from model. Response: {}", response_json))?;

        let content = choice.get("message")
            .and_then(|m| m.get("content"))
            .and_then(|c| c.as_str())
            .map(|s| s.to_string());
        
        let tool_calls = choice.get("message")
            .and_then(|m| m.get("tool_calls"))
            .and_then(|calls| calls.as_array())
            .map(|calls| {
                calls.iter().filter_map(|call| {
                    let id = call.get("id")?.as_str()?.to_string();
                    let r#type = call.get("type")?.as_str()?.to_string();
                    let name = call.get("function")?.get("name")?.as_str()?.to_string();
                    let arguments = call.get("function")?.get("arguments")?.as_str()?.to_string();
                    Some(ToolCall {
                        id,
                        r#type,
                        function: ToolFunction { name, arguments },
                    })
                }).collect()
            });

        Ok(ChatCompletionResponse { content, tool_calls })
    }

    async fn get_embedding(&self, text: &str) -> anyhow::Result<Vec<f32>> {
        let client = reqwest::Client::new();
        let base_url = self.url.trim_end_matches('/');
        let response = client
            .post(format!("{}/embedding", base_url))
            .json(&serde_json::json!({ "content": text }))
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        let embedding = response["embedding"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("Embeddings not supported or invalid response from server"))?
            .iter()
            .filter_map(|v| v.as_f64().map(|f| f as f32))
            .collect();

        Ok(embedding)
    }

    async fn tokenize(&self, text: &str) -> anyhow::Result<Vec<u32>> {
        let client = reqwest::Client::new();
        let base_url = self.url.trim_end_matches('/');
        let response = client
            .post(format!("{}/tokenize", base_url))
            .json(&serde_json::json!({ "content": text }))
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        let tokens = response["tokens"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("Tokenization failed"))?
            .iter()
            .filter_map(|v| v.as_u64().map(|u| u as u32))
            .collect();

        Ok(tokens)
    }

    async fn detokenize(&self, tokens: Vec<u32>) -> anyhow::Result<String> {
        let client = reqwest::Client::new();
        let base_url = self.url.trim_end_matches('/');
        let response = client
            .post(format!("{}/detokenize", base_url))
            .json(&serde_json::json!({ "tokens": tokens }))
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        let content = response["content"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Detokenization failed"))?
            .to_string();

        Ok(content)
    }

    async fn list_models(&self) -> anyhow::Result<Vec<String>> {
        let client = reqwest::Client::new();
        let base_url = self.url.trim_end_matches('/');
        let endpoint = if base_url.ends_with("/v1") {
            format!("{}/models", base_url)
        } else {
            format!("{}/v1/models", base_url)
        };

        let response = client.get(endpoint).send().await?.json::<serde_json::Value>().await?;
        
        let models = response["data"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("Could not list models"))?
            .iter()
            .filter_map(|m| m["id"].as_str().map(|s| s.to_string()))
            .collect();

        Ok(models)
    }

    async fn health_check(&self) -> anyhow::Result<bool> {
        let client = reqwest::Client::new();
        let base_url = self.url.trim_end_matches('/');
        let response = client.get(format!("{}/health", base_url)).send().await?;
        Ok(response.status().is_success())
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

        let response_json = rb
            .json(&request_json)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        if let Some(error) = response_json.get("error") {
            anyhow::bail!("OpenAI Error: {}", error.get("message").and_then(|m| m.as_str()).unwrap_or("Unknown error"));
        }

        let choice = response_json.get("choices")
            .and_then(|c| c.as_array())
            .and_then(|a| a.get(0))
            .ok_or_else(|| anyhow::anyhow!("No choices returned from model. Response: {}", response_json))?;

        let content = choice.get("message")
            .and_then(|m| m.get("content"))
            .and_then(|c| c.as_str())
            .map(|s| s.to_string());
        
        let tool_calls = choice.get("message")
            .and_then(|m| m.get("tool_calls"))
            .and_then(|calls| calls.as_array())
            .map(|calls| {
                calls.iter().filter_map(|call| {
                    let id = call.get("id")?.as_str()?.to_string();
                    let r#type = call.get("type")?.as_str()?.to_string();
                    let name = call.get("function")?.get("name")?.as_str()?.to_string();
                    let arguments = call.get("function")?.get("arguments")?.as_str()?.to_string();
                    Some(ToolCall {
                        id,
                        r#type,
                        function: ToolFunction { name, arguments },
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

        let response_json = rb
            .json(&serde_json::json!({
                "input": text,
                "model": "text-embedding-3-small"
            }))
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        let data = response_json.get("data")
            .and_then(|d| d.as_array())
            .ok_or_else(|| anyhow::anyhow!("Invalid embedding response: 'data' missing"))?;
        
        let first = data.get(0)
            .ok_or_else(|| anyhow::anyhow!("Invalid embedding response: 'data' empty"))?;
            
        let embedding_json = first.get("embedding")
            .and_then(|e| e.as_array())
            .ok_or_else(|| anyhow::anyhow!("Invalid embedding response: 'embedding' missing"))?;

        let embedding: Vec<f32> = embedding_json.iter()
            .filter_map(|v| v.as_f64().map(|f| f as f32))
            .collect();

        Ok(embedding)
    }

    async fn tokenize(&self, text: &str) -> anyhow::Result<Vec<u32>> {
        let client = reqwest::Client::new();
        let base_url = self.url.trim_end_matches('/');
        let response = client
            .post(format!("{}/tokenize", base_url.trim_end_matches("/v1")))
            .json(&serde_json::json!({ "content": text, "model": self.model_id }))
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        let tokens = response["tokens"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("Tokenization failed or endpoint not found"))?
            .iter()
            .filter_map(|v| v.as_u64().map(|u| u as u32))
            .collect();

        Ok(tokens)
    }

    async fn detokenize(&self, tokens: Vec<u32>) -> anyhow::Result<String> {
        let client = reqwest::Client::new();
        let base_url = self.url.trim_end_matches('/');
        let response = client
            .post(format!("{}/detokenize", base_url.trim_end_matches("/v1")))
            .json(&serde_json::json!({ "tokens": tokens, "model": self.model_id }))
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;

        let content = response["content"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Detokenization failed"))?
            .to_string();

        Ok(content)
    }

    async fn list_models(&self) -> anyhow::Result<Vec<String>> {
        let client = reqwest::Client::new();
        let base_url = self.url.trim_end_matches('/');
        let endpoint = if base_url.ends_with("/v1") {
            format!("{}/models", base_url)
        } else {
            format!("{}/v1/models", base_url)
        };

        let mut rb = client.get(endpoint);
        if let Some(key) = &self.api_key {
            rb = rb.header("Authorization", format!("Bearer {}", key));
        }

        let response = rb.send().await?.json::<serde_json::Value>().await?;
        
        let models = response["data"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("Could not list models"))?
            .iter()
            .filter_map(|m| m["id"].as_str().map(|s| s.to_string()))
            .collect();

        Ok(models)
    }

    async fn health_check(&self) -> anyhow::Result<bool> {
        let client = reqwest::Client::new();
        let base_url = self.url.trim_end_matches('/');
        let response = client.get(format!("{}/health", base_url.trim_end_matches("/v1"))).send().await?;
        Ok(response.status().is_success())
    }
}
