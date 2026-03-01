# Pecan: Persistent Agent Framework

Pecan is a Swift-based coding agent framework that emphasizes secure, isolated execution via containers. The architecture centers around a powerful server, a clean user interface, and isolated agents that rely entirely on the server for capabilities.

## Architecture

### 1. `pecan-server` (The Host Daemon)
A persistent gRPC background process that acts as the control plane:
- Manages agent sessions and autonomous execution loops.
- Owns the connection to LLM providers (e.g., OpenAI, Anthropic, local MLX/llama.cpp models).
- Owns all external internet access.
- Spawns and manages isolated containers for agents to run in.
- Handles tool execution requests from the isolated agents via gRPC.

### 2. `pecan-agent` (The Isolated Worker)
The agent process that actually runs *inside* the container:
- Completely isolated from the internet. No direct access to LLM APIs or external resources.
- Connects back to the `pecan-server` via gRPC to request LLM completions, run tools, or interact with the user.
- Operates within a controlled, potentially virtualized filesystem environment (VFS).
- **Tool Execution:** All tools (Lua scripts, built-in binary tools) execute strictly within the agent's isolated process. The server acts purely as a router and proxy for these tools. If a tool requires host-level capabilities (like fetching a web page or modifying host files), it must do so by requesting that specific capability from the server via the gRPC link, rather than the server executing the tool directly.

### 3. `pecan` (The User Interface)
The client application used to interact with the server:
- Connects to the `pecan-server` to start new tasks, monitor progress, and provide Human-in-the-Loop (HITL) approvals.
- Could be a rich terminal application (TUI) or a macOS native app.

## Key Concepts

### Pluggable VM / Container Execution
Agents execute code, run tests, and manipulate files inside a dedicated, isolated environment. This prevents an agent from accidentally deleting the user's home directory or exfiltrating sensitive local data. The architecture is designed to be pluggable:
- **macOS Native:** Utilizes Apple's `Virtualization.framework` for native, incredibly fast, and lightweight Linux VMs without requiring Docker.
- **Cross-Platform / Linux:** Utilizes `Firecracker` microVMs for near-instant startup times and strong hardware-level isolation.
- **Fallbacks:** Designed to easily plug in traditional container engines like Docker or Podman in the future if needed.

### Tailscale Integration
The server can optionally join a Tailnet (using a userspace implementation or by interfacing with a local Tailscale daemon), making the agent and its server accessible securely from any device on the same Tailnet without exposing it to the public internet. This enables remote execution and monitoring of autonomous loops.

### gRPC Control Plane
All agent capabilities (reasoning, fetching web pages, creating files outside the container) are routed through the gRPC connection to the server. The server acts as a strict policy engine, deciding what the agent is allowed to do.

### Virtual Filesystem (VFS) & Diffing
The container may utilize a virtual filesystem that tracks the agent's changes as a "diff" against the original workspace. This allows the user to review all changes the agent made during its session before committing them to the actual host filesystem.

## Development Phases

1.  **Core Communication & Non-Containerized Execution:**
    Establish bidirectional gRPC streaming between the `pecan` (UI), `pecan-server`, and `pecan-agent`. Get the basic agent reasoning loop, tool execution (via the server), and user interaction working with the agent running directly on the host (outside a container) to stabilize the protocol.
2.  **Containerization Lifecycle:**
    Implement the pluggable VM architecture (`Virtualization.framework`, `Firecracker`). The server will spawn these isolated environments, inject the `pecan-agent` binary, and establish the gRPC connection across the VM boundary.
3.  **Built-in Server Tools:**
    Implement a robust suite of built-in tools hosted by the `pecan-server`. Because agents will eventually run in locked-down containers without internet or standard host access, the server must provide essential capabilities (e.g., secure web fetching, controlled file system operations, git interactions) over gRPC.
