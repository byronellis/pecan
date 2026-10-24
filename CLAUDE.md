# Pecan — Claude Code Instructions

## Toolchain

Requires macOS 27 and Swift 6.4 (`.swift-version` pins 6.4.1 for swiftly). Older toolchains
can't read the macOS 27 SDK.

## Build with `make`

`make` embeds a version, build number and channel in the executable (`__TEXT,__info_plist`,
read by `Sources/PecanSettings/BuildInfo.swift`). Clients compare these to decide whether to
replace the running server, so use `make` for anything you intend to run.

| Command | What it does |
|---|---|
| `make` / `make debug` | Debug build, dev channel |
| `make release` | Optimized build, dev channel |
| `make dist BUILD_NUMBER=n` | Optimized build, release channel (CI; `n` = CI run number) |
| `make clean` | `swift package clean` |

- Dev build numbers come from `~/.pecan-dev/build-counter`, incremented by every dev build.
- A plain `swift build` works but produces an unversioned build that never upgrades a server.
- Never commit `Package.swift` with a local `.package(path:)` dependency.

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
- `pecan server status|stop|start` manage the server. `PECAN_LOG_LEVEL=debug` in a client's
  environment reaches the server it starts (stop the running one first).
- Sessions live in the server and form trees: a main session, with sub-sessions, forks and side
  conversations under it (`Sources/PecanProtocol/Sessions.swift`). There are no named agents or
  teams. A turn's reply streams to the client as `session.event` notifications, then the
  `session.send` request answers. Sessions are in memory only and end with their connection.

## Terminal UI

`pecan` (no arguments) is an inline chat, not a full-screen app: finished output is printed
into the terminal's own scrollback, and only a small live region at the bottom (streaming line,
rounded input box, status line) is redrawn (`Sources/PecanUI/Terminal/InlineScreen.swift`).
`pecan "message"` or piped input answers once, as plain text.

To see what the UI draws, run it under a pseudo-terminal and feed the output to a terminal
emulator such as `pyte`; it can't be exercised from a plain pipe.

| Target | Role |
|---|---|
| `PecanSettings` | `BuildInfo`, `PecanPaths` |
| `PecanProtocol` | JSON-RPC wire types, socket client, connect-or-start/upgrade logic (no MLX) |
| `PecanServer` | `PecanServerHost` (resident server), FoundationModels sessions |
| `PecanAgentCore` | Tools, prompt composer |
| `PecanUI` | `pecan` executable: ArgumentParser commands, inline terminal UI |

## Related repositories

- **pecan-mlx** (`~/Sources/pecan-mlx`) — MLX inference server for Apple Silicon
- **pecan-gb10** (`~/Sources/pecan-gb10`) — LLM inference server for NVIDIA DGX Spark
