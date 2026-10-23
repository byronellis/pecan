# Pecan — Claude Code Instructions

## Toolchain

Requires macOS 27 and Swift 6.4 (`.swift-version` pins 6.4.1 for swiftly). Older toolchains
can't read the macOS 27 SDK. MLX needs Xcode's Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`).

## Build with `make`

`make` embeds a version, build number and channel in the executable (`__TEXT,__info_plist`,
read by `Sources/PecanSettings/BuildInfo.swift`). Clients compare these to decide whether to
replace the running server, so use `make` for anything you intend to run.

| Command | What it does |
|---|---|
| `make` / `make debug` | Debug build, dev channel |
| `make release` | Optimized build, dev channel |
| `make dist BUILD_NUMBER=n` | Optimized build, release channel (CI; `n` = CI run number) |
| `make LOCAL_TUISUITE=1` | Build against `../../Masters/tuisuite` instead of GitHub |
| `make clean` | `swift package clean` |

- Dev build numbers come from `~/.pecan-dev/build-counter`, incremented by every dev build.
- A plain `swift build` works but produces an unversioned build that never upgrades a server.
- Never commit `Package.swift` with a local `.package(path:)`; TUISuite is switched by the
  `TUISUITE_PATH` environment variable instead.

## Architecture

- One `pecan` executable. `pecan server run` is the resident server; every other command is a
  client that connects to it over a unix socket, starting it (detached, in its own session) if
  needed.
- A client newer than the running server (same channel) stops it and starts its own build.
  Older or unversioned clients connect without restarting it.
- Channels are isolated: dev builds use `~/.pecan-dev/`, release builds `~/.pecan/`, and
  `PECAN_HOME` overrides both. Runtime files live in `<home>/run/` (`pecan.sock`,
  `server.lock`, `server.log`).
- `server.lock` (flock) guarantees one server per channel.
- `pecan server status|stop|start` manage the server.

| Target | Role |
|---|---|
| `PecanSettings` | Config (YAML), keychain, `BuildInfo`, `PecanPaths` |
| `PecanProtocol` | JSON-RPC wire types, socket client, connect-or-start/upgrade logic (no MLX) |
| `PecanServer` | `PecanServerHost` (resident server), HTTP LLM proxy, MLX |
| `PecanAgentCore` | Tools, hooks, Lua runtime, prompt composer |
| `PecanUI` | `pecan` executable: ArgumentParser commands, TUISuite UI |

## Related repositories

- **tuisuite** (`~/Masters/tuisuite`) — the TUI library Pecan's CLI is built on, developed by
  hand alongside Pecan; discuss changes before editing it
- **pecan-mlx** (`~/Sources/pecan-mlx`) — MLX inference server for Apple Silicon
- **pecan-gb10** (`~/Sources/pecan-gb10`) — LLM inference server for NVIDIA DGX Spark
