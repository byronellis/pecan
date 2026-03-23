# Pecan: Design Document

## Architecture

### 1. `pecan-server` (The Host Daemon)

A persistent gRPC background process that acts as the control plane:

- Manages agent sessions with per-session SQLite databases for context, tasks, memories, and triggers.
- Owns the connection to LLM providers via a pluggable provider system (any OpenAI-compatible API endpoint).
- Owns all external internet access, proxying web fetch, web search, and HTTP requests on behalf of isolated agents.
- Spawns and manages isolated containers via the `pecan-vm-launcher` child process.
- Maintains bidirectional gRPC streams to both agents and UI clients.

**Key files:**
- `Sources/PecanServer/main.swift` -- Server entry point, gRPC service, SessionManager actor.
- `Sources/PecanServer/SessionStore.swift` -- Per-session SQLite database (context, tasks, memories, triggers).
- `Sources/PecanServer/RemoteSpawner.swift` -- IPC client for communicating with the VM launcher.
- `Sources/PecanServer/VMManager.swift` -- MountSpec definitions and spawner protocol.

### 2. `pecan-vm-launcher` (The Container Manager)

A privileged child process managed by `pecan-server` that handles container lifecycle:

- Uses Apple's Containerization framework (macOS 15.0+) to create lightweight Linux VMs.
- Each agent gets an Alpine 3.19 container with 2 CPUs, 512MB RAM, and a 1GB rootfs.
- Relays the gRPC Unix socket into the container via vsock at `/tmp/grpc.sock`.
- Mounts workspace, agent binary, tools, and skills directories into the container.
- Sets `HOME` and `USER` environment variables for the agent process.
- Container output logged to `.run/containers/{sessionID}.log`.

**Key files:**
- `Sources/PecanVMLauncher/ContainerSpawner.swift` -- Container creation, configuration, and lifecycle.
- `Sources/PecanVMLauncher/IPCProtocol.swift` -- IPC message types for spawn/terminate commands.

### 3. `pecan-agent` (The Isolated Worker)

The agent process that runs inside the container:

- Completely isolated from the internet. No direct access to LLM APIs or external resources.
- Connects to `pecan-server` via gRPC over the relayed Unix socket.
- All tools execute locally inside the container. Only LLM completions and external network requests are proxied through the server.
- System prompt composed from modular fragments (identity, guidelines, memory + CORE.md content, skill catalog, etc.).
- Supports dynamic extension via Lua tools, prompt fragments, hooks, and Agent Skills.

**Key files:**
- `Sources/PecanAgent/main.swift` -- Agent entry point, gRPC event loop, tool execution dispatch.
- `Sources/PecanAgent/ToolManager.swift` -- Tool registry, Lua tool loading, tool definitions.
- `Sources/PecanAgent/BuiltinTools.swift` -- All built-in tool implementations.
- `Sources/PecanAgent/PromptComposer.swift` -- System prompt composition from fragments.
- `Sources/PecanAgent/SkillManager.swift` -- Agent Skills discovery, cataloging, and activation.
- `Sources/PecanAgent/HookManager.swift` -- Event-driven Lua hook system.
- `Sources/PecanAgent/LuaTool.swift` -- Lua tool execution (module and legacy modes).

### 4. `pecan` (The User Interface)

A terminal UI application:

- Markdown rendering with headers, bold, italic, inline code, code blocks, and bullet lists.
- Box-drawn Unicode tables from markdown table syntax.
- Spinner animations and status chrome showing agent names and activity.
- Tool call and result display with formatted output and truncation.
- Connects to `pecan-server` via gRPC to manage sessions and provide HITL approvals.

**Key files:**
- `Sources/Pecan/main.swift` -- TUI entry point, rendering, input handling.

## Data Flow

```
┌──────────┐     gRPC      ┌──────────────┐     gRPC/vsock     ┌─────────────┐
│  pecan   │◄──────────────►│ pecan-server │◄───────────────────►│ pecan-agent │
│  (TUI)   │   UI stream    │  (daemon)    │   agent stream      │ (container) │
└──────────┘                │              │                     │             │
                            │  SQLite DB   │     IPC socket      │  Lua tools  │
                            │  LLM proxy   │◄──────────────────►│  Skills     │
                            │  HTTP proxy  │  pecan-vm-launcher  │  Hooks      │
                            └──────────────┘                     └─────────────┘
```

## Container Mounts

| Host Path | Container Path | Mode | Notes |
|-----------|---------------|------|-------|
| `.build/aarch64-swift-linux-musl/release/` | `/opt/pecan` | read-only | Agent binary |
| `~/.pecan/tools/` | `/home/{agentName}/.pecan/tools/` | read-only | User Lua tools |
| `{projectDir}` | `/project-lower` | read-only (virtiofs) | Project lower layer |
| *(in-container)* | `/project-upper` | read-write | COW upper layer (local to container) |
| *(in-container)* | `/project` | FUSE overlay | Merged view (lower + upper) |
| *(gRPC-backed)* | `/memory` | FUSE | Memory filesystem |
| *(gRPC-backed)* | `/skills` | FUSE COW | Skills catalog (lower from server, upper at `/tmp/skills-upper`) |

The project lower layer is mounted read-only so agents can never corrupt the host project directly. All writes land in `/project-upper` and are merged back on `/changeset:submit`.

Memory and skills filesystems are backed by gRPC calls to the server rather than host mounts, keeping all persistence server-side.

## Tool System

### Tool Tags

Tools carry tags that control whether they are sent to the LLM as structured tool definitions:

- `core` -- Always active: `read_file`, `write_file`, `append_file`, `edit_file`, `search_files`, `bash`.
- `web` -- Always active: `web_fetch`, `web_search` (proxied through server).
- `skills` -- Always active: `activate_skill` for loading Agent Skills.
- `invoke_only` -- Registered in `ToolManager` but never sent to the LLM. Accessible to skill scripts via `pecan-agent invoke <tool> '<json>'`. Includes: `http_request`, `create_lua_tool`, all task tools, all trigger tools.

The `PromptComposer` maintains the active tag set (`core`, `web`, `skills`) and only includes matching tools in LLM requests. This keeps the tool count at 9, reducing token overhead per turn.

### Lua Tool Specification

Lua tools use a **module pattern**. The script returns a table with metadata and an `execute` function:

```lua
return {
    -- Metadata (used for tool registration)
    name = "tool_name",                    -- required
    description = "What the tool does.",   -- required
    schema = '{"type":"object",...}',       -- JSON Schema for parameters

    -- Main execution function (required)
    -- Receives parsed arguments as a Lua table
    -- Must return a string result
    execute = function(args)
        return "result string"
    end,

    -- Optional: format the raw result for compact UI display
    format_result = function(result)
        return "short summary"
    end
}
```

**Loading order:**
1. Built-in tools registered via `ToolManager.registerBuiltinTools()`
2. User Lua tools from `~/.pecan/tools/*.lua` (module pattern auto-detected)
3. Skill Lua tools from `~/.pecan/skills/*/scripts/*.lua`

A **legacy mode** is also supported where the script returns a function directly (requires a `.json` sidecar with schema), but the module pattern is preferred.

## Prompt Composition

The system prompt is built from independent **PromptFragment** instances, sorted by priority (lower = earlier):

| Priority | Fragment | Description |
|----------|----------|-------------|
| 0 | `BaseIdentityFragment` | Agent identity and role |
| 50 | `ProjectTeamContextFragment` | Active project/team name and mount paths |
| 100 | `GuidelinesFragment` | Tool usage best practices |
| 200 | `MemoryFragment` | Memory system instructions + CORE.md content for each active scope |
| 250 | `FocusedTaskFragment` | Currently focused task (if set) |
| 350 | `SkillCatalogFragment` | Discovered skills with names and descriptions |
| 450+ | User fragments | Custom Lua fragments from `~/.pecan/prompts/*.lua` |

`MemoryFragment` reads `/memory/CORE.md`, `/memory/project/CORE.md`, and `/memory/team/CORE.md` directly at prompt composition time and inlines their content. No asynchronous injection is needed.

## Agent Skills

Pecan implements the [Agent Skills](https://agentskills.io) open standard with a Pecan-specific extension for Lua tools.

### Skill Structure

```
skill-name/
  SKILL.md          # Required: YAML frontmatter + markdown instructions
  scripts/          # Optional: Lua tools auto-registered on discovery
    helper.lua
  references/       # Optional: reference documents
  assets/           # Optional: templates, configs, etc.
```

### SKILL.md Format

```markdown
---
name: My Skill
description: A brief description of what this skill does.
---

Full instructions for the agent go here. These are only loaded
when the agent activates the skill via the activate_skill tool.
```

### Progressive Disclosure

1. **Discovery** (startup): Scan `~/.pecan/skills/` and `~/.agents/skills/` for `SKILL.md` files.
2. **Catalog** (system prompt): Inject skill names and descriptions so the agent knows what's available.
3. **Activation** (on demand): When a task matches a skill, the agent calls `activate_skill` to load the full instructions and resource listing.
4. **Lua tools** (startup): Any `.lua` files in a skill's `scripts/` directory are registered as tools immediately, regardless of activation.

## Hook System

Hooks are event-driven Lua scripts in `~/.pecan/hooks/` that react to agent lifecycle events:

```lua
return {
    on = { "agent.registered", "tool.before", "tool.after", "agent.shutdown" },

    handler = function(event, data)
        -- event: string name of the event
        -- data: table with event-specific fields
    end
}
```

**Events:**
- `agent.registered` -- Agent has connected and registered with the server.
- `tool.before` -- Fired before each tool execution (data includes `name`, `arguments`, `active_tags`).
- `tool.after` -- Fired after each tool execution (data includes `name`, `arguments`, `result`).
- `agent.shutdown` -- Agent is shutting down (data includes `reason`).

## Session Persistence

Each session is stored at `~/.pecan/sessions/{sessionID}/`:

- `session.db` -- SQLite database containing:
  - Session metadata (name, status, timestamps)
  - Context messages (system, conversation, tool sections)
  - Tasks (with status, priority, severity, labels, dependencies)
  - Memories (with content and tags; `core` tag triggers system prompt injection)
  - Triggers (scheduled instructions with one-shot or repeating semantics)
- `workspace/` -- The agent's working directory, mounted read-write into the container.

## Agent Startup Flow

1. Mount FUSE filesystems: `/memory` (gRPC-backed), `/skills` (gRPC-backed COW), `/project` (overlay: `/project-lower` + `/project-upper`) on OS threads to avoid cooperative thread pool starvation
2. Register built-in tools (`ToolManager.registerBuiltinTools()`)
3. Load user Lua tools from `~/.pecan/tools/*.lua`
4. Load hooks from `~/.pecan/hooks/*.lua`
5. Discover skills from `/skills/` and `~/.agents/skills/`
6. Register Lua tools from skill `scripts/` directories
7. Register built-in prompt fragments
8. Load user prompt fragments from `~/.pecan/prompts/*.lua`
9. Connect to server via gRPC
10. Send registration; server responds with project/team context
11. Compose system prompt (reads CORE.md files from FUSE at this point) and send to server context store
12. Enter event loop
