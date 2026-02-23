# Pecan: Persistent Local Agent Framework

Pecan is a Rust-based coding agent designed for local and network-local models (llama.cpp, vLLM, MLX, Ollama). It emphasizes persistence, secure remote access, and a Zellij-like multiplexed interface.

## Architecture

### 1. `pecan-server` (The Daemon)
A persistent background process that:
- Manages agent sessions and "Ralph Wiggum Loops" (autonomous/semi-autonomous execution loops).
- Stores conversation history and state.
- Hosts a communication socket (Unix Domain Socket or TCP via Tailscale).
- Integrates with Tailscale for secure, peer-to-peer remote access.

### 2. `pecan-core`
The engine shared by both the server and local CLI:
- **Agent Loop:** Reasoning and execution logic.
- **Tool Registry:** Standardized interface for agent capabilities (shell, FS, web).
- **Persistence:** Layer for saving/loading agent states.

### 3. `pecan-providers`
Abstractions for LLM backends:
- **Local:** `llama.cpp` (direct/HTTP), `MLX`, `Ollama`.
- **Remote/Network:** `vLLM`, DGX Spark-based servers.

### 4. `pecan-tui`
A Zellij-inspired interface:
- **Ratatui Frontend:** Rich terminal interface.
- **Multiplexing:** Ability to attach/detach from `pecan-server` sessions.
- **Web-based TUI:** Rendering the TUI in a browser for remote access.

## Key Concepts

### Ralph Wiggum Loops
Autonomous execution loops where the agent pursues a goal persistently. The server manages these loops, allowing the user to check in on progress, intervene, or "attach" to the loop's UI session.

### Tailscale Awareness
The server can optionally join a Tailnet using `tsnet`, making the agent accessible from any device on the same tailnet without exposing it to the public internet.
