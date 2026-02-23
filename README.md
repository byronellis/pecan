# Pecan: Persistent Local Agent Framework

Pecan is a Rust-based coding agent framework designed for local and network-local models. It provides a persistent daemon for managing agent sessions, a rich terminal interface, and secure remote access.

## Features (Planned & In Progress)
- **Local Model Support:** First-class support for `llama.cpp`, `Ollama`, and `MLX`.
- **Persistent Daemon:** `pecan-server` manages autonomous agent loops.
- **Multiplexed TUI:** A Zellij-like interface for interacting with agents.
- **Tailscale Integration:** Secure remote access to your agents "on the go".
- **Tool Registry:** Extensible tool system for shell, file system, and web access.

## Project Structure
- `pecan-cli`: Main command-line interface.
- `pecan-server`: Persistent background daemon and API.
- `pecan-core`: Core agent reasoning and state management.
- `pecan-providers`: LLM backend abstractions.
- `pecan-tui`: Terminal user interface components.

## Getting Started

### CLI Mode
```bash
cargo run -p pecan-cli -- --mock
```

### TUI Mode (Placeholder)
```bash
cargo run -p pecan-cli -- --tui --mock
```

### Server Mode
```bash
cargo run -p pecan-server
```

## Documentation
See [DESIGN.md](DESIGN.md) for architectural details.
