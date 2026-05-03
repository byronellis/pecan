# Pecan — Claude Code Instructions

## Always use `make`, never `swift build` directly

`pecan-vm-launcher` requires the `com.apple.security.virtualization` entitlement
(for Containerization / vmnet). Swift Package Manager cannot apply entitlements,
so the binary must be codesigned immediately after linking. The Makefile handles
both steps atomically.

## Build targets

| Command | What it does |
|---|---|
| `make` | Release build of all macOS products + Linux agent, then codesign |
| `make release` | macOS release products + codesign (skips Linux agent) |
| `make agent` | Cross-compile `pecan-agent` for Linux musl (aarch64) only |
| `make debug` | Debug build of macOS products + codesign (fast iteration) |
| `make clean` | `swift package clean` |

**Important:** `make debug` does NOT build the Linux agent. Changes to
`PecanAgentCore` or `PecanAgent` that need to run inside the container
require `make agent` (or `make` for a full release build).

The container mounts `.build/aarch64-swift-linux-musl/release/` at `/opt/pecan`
as a live mount — no image rebuild needed after `make agent`.

## Multi-repo development (pecan-shared)

This repo depends on [pecan-shared](https://github.com/byronellis/pecan-shared),
which holds shared gRPC/protobuf definitions and `Config`. When making changes
across both repos simultaneously:

```
make use-local    # Switch Package.swift to .package(path: "../pecan-shared")
                  # Work on both repos, build freely

make use-remote   # Switch back to GitHub URL + run swift package update pecan-shared
                  # Do this before committing — never commit the local path
```

**Never commit `Package.swift` while it contains `.package(path: "../pecan-shared")`.**
The `use-remote` target updates `Package.resolved` automatically.

Workflow:
1. Push pecan-shared changes to GitHub first
2. `make use-remote` in this repo (picks up the new commit)
3. Commit and push this repo

## Related repositories

- **pecan-shared** (`~/Sources/pecan-shared`) — shared gRPC/proto definitions; push changes here first
- **pecan-mlx** (`~/Sources/pecan-mlx`) — MLX inference server for Apple Silicon
- **pecan-gb10** (`~/Sources/pecan-gb10`) — LLM inference server for NVIDIA DGX Spark

## Architecture notes

- The agent (`pecan-agent`, Linux musl) runs inside an ephemeral Alpine 3.19 VM
- gRPC socket relayed into container at `/tmp/grpc.sock`
- All conversation state is stored server-side via `SessionManager` (SQLite); the
  agent has no persistent in-memory state across restarts
- System prompt (section 0) is cleared and rewritten on every agent registration
  to prevent stacking duplicates across container restarts
