use axum::{
    routing::post,
    Json, Router, extract::Path, Extension,
};
use pecan_core::Agent;
use pecan_providers::{MockProvider};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex as AsyncMutex;
use uuid::Uuid;

#[derive(Debug, Serialize, Deserialize)]
struct CreateSessionRequest {
    provider: String, // "mock", "llama.cpp", etc.
}

#[derive(Debug, Serialize, Deserialize)]
struct CreateSessionResponse {
    session_id: Uuid,
}

#[derive(Debug, Serialize, Deserialize)]
struct ChatRequest {
    message: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct ChatResponse {
    response: String,
}

struct AppState {
    sessions: AsyncMutex<HashMap<Uuid, Arc<Agent>>>,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let state = Arc::new(AppState {
        sessions: AsyncMutex::new(HashMap::new()),
    });

    let app = Router::new()
        .route("/sessions", post(create_session))
        .route("/sessions/:id/chat", post(chat))
        .layer(Extension(state));

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    println!("Pecan Server listening on http://0.0.0.0:3000");
    axum::serve(listener, app).await.unwrap();
}

async fn create_session(
    Extension(state): Extension<Arc<AppState>>,
    Json(_req): Json<CreateSessionRequest>,
) -> Json<CreateSessionResponse> {
    let session_id = Uuid::new_v4();
    let config = pecan_core::config::Config::load().unwrap();
    let agent = Arc::new(Agent::new(config, &format!("session_{}", session_id)).await.unwrap());
    
    let mut sessions = state.sessions.lock().await;
    sessions.insert(session_id, agent);

    Json(CreateSessionResponse { session_id })
}

async fn chat(
    Path(session_id): Path<Uuid>,
    Extension(state): Extension<Arc<AppState>>,
    Json(req): Json<ChatRequest>,
) -> Json<ChatResponse> {
    let sessions = state.sessions.lock().await;
    if let Some(agent) = sessions.get(&session_id) {
        let agent = agent.clone();
        drop(sessions); // Release sessions lock

        match agent.chat(req.message).await {
            Ok(response) => Json(ChatResponse { response }),
            Err(e) => Json(ChatResponse {
                response: format!("Error: {}", e),
            }),
        }
    } else {
        Json(ChatResponse {
            response: "Session not found".to_string(),
        })
    }
}
