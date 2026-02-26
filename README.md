# Pecan: Persistent Agent Framework

Pecan is a Swift-based coding agent framework that emphasizes secure, isolated execution via containers. The architecture centers around a powerful server, a clean user interface, and isolated agents that rely entirely on the server for capabilities.

## Architecture

Pecan is divided into three main components:

1. **`pecan-server` (The Host Daemon)**
   A persistent gRPC background process that acts as the control plane. It manages agent sessions, owns the connection to LLM providers (e.g., OpenAI, Anthropic, local MLX/llama.cpp models), and securely handles tool execution requests from isolated agents.

2. **`pecan-agent` (The Isolated Worker)**
   The agent process that actually runs *inside* an isolated environment (like a macOS Virtualization.framework VM or Firecracker). It has no direct internet access and connects back to the server via gRPC to request LLM completions and tool executions.

3. **`pecan` (The User Interface)**
   A Terminal User Interface (TUI) application used to interact with the server. It connects to the server via gRPC to start new tasks, monitor progress, and provide Human-in-the-Loop (HITL) approvals.

## Key Features

- **Containerized Execution:** Designed for agents to execute code safely inside dedicated VMs/Containers.
- **gRPC Control Plane:** All capabilities are routed through the server, which acts as a strict policy engine.
- **Centralized Context:** The server holds and manages conversation context to minimize data serialized across the VM boundary.
- **Pluggable LLMs:** Easily configurable to talk to standard OpenAI API endpoints, local MLX, or remote vLLM clusters.
- **Tailscale Ready:** Designed with networking in mind for secure remote management over Tailnets.

## Getting Started

### Configuration

Create a configuration file at `~/.pecan/config.yaml`:

```yaml
default_model: qwen3
models:
  qwen3:
    name: qwen3
    provider: openai
    url: 'http://spark-ad32.local:8000'
    api_key: none
    model_id: Qwen/Qwen3-Coder-Next-FP8
```

### Running the Server

During development, you can use the background helper scripts to run the server:

```bash
./dev_restart.sh
```
This builds the project and starts the server in the background. You can tail its logs using `tail -f .run/server.log`. To stop it, run `./dev_stop.sh`.

### Running the UI

Start the interactive terminal UI:

```bash
swift run pecan
```

## Documentation

See [DESIGN.md](DESIGN.md) for deeper architectural details and the roadmap.
