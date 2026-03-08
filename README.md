# Pecan: Persistent Extensible Containerized AgeNts

Yeah, the name is a bit of a stretch, but I'm fine with that. Pecan is an experimental agentic coding harness intended more as an exploration of different ideas in the space rather than simply copying whatever it happens to be that 
Claude Code is doing this week. Which isn't a knock on Claude Code, I use it and it's pretty good. But these harnesses introduce quite a bit of pre- and post- processing and other assumptions so at the end of the day it's still 
really about how Anthropic things I should code, not necessarily how I code (for whatever value of code we're going with these days). 

Or it could just be what a friend of mine said the other day when I was showing him the very very beginning of the project: "This is like a Jedi thing isn't it?" And, yeah, maybe it is. Anyway, I wanted to do it and so I'm doing it.

## Questions You Might Have

### You do know about sandboxes, right?

Yes, I do and this approach is similar in spirit in that you want the agent locked away. The primary difference though is more of a mindset thing.. In the sandbox model you have to spend some time configuring
things to make the sandbox work because the cli doesn't want to be super opionated about that. Pecan is more of a kubernetes-style approach with the pecan-server taking on the role of the k8s control plane in
a lot of ways and doing things like, say, controlling networking and so on. So same goals, different philosophy of implementation. Mainly Pecan is a "Sandbox First" model (really its Sandbox Only). 

### Swift?

Yeah, Swift. Look, I started the project in Rust and I decided driving home one night that I just... don't like Rust. I don't like writing it, I don't like reading it. It's just not a language I want to use. So I picked a language that
I do actually enjoy writing and reading instead. Also, I mostly develop on Macs and there's the Virtualization and Containerization frameworks and I'm interested using those to see if that changes things at all. 

Honestly, I actually like Apple's toolchains. They're usually pretty good, though I do think it's time for a Snow Leopard-style pause so it's good that they're doing that. I even happen to think Xcode is one of the better IDEs out there
precisely because it doesn't try to be an everything bagel-type of tool. It's still doing the Clippy sidekick agent thing, but hey maybe someday we'll see Terminal.app support things like Powerline and Kitty Keyboard Protocol and a really pretty ANSI Xcode TUI. Stranger things have happened.

### What's with the local LLM focus?

Mainly because while in my professional life whomever I'm working for will have some sort of contract with a "token provider" in my personal life I won't have that sort of leverage and will be stuck with whatever the providers want to 
give me. Let's take Anthropic for example, my least favorite thing about Claude Code is the circuit breaker thing. I get why they do it and in their shoes I would probably do the same, but my life is such that I do relatively short bursts
of work and then go off and do other things. With Anthropic I hit the circuit breaker in minutes a lot of times whereas Gemini lets me burn all of my tokens for the day at once. So, even though I'd probably prefer to use Claude, I tend to
use Gemini more often because it fits mny work style better. 

But I don't particularly like the fact they anybody gets to dictate my personal work style (paid, different story). I'm also interested in seeing if I can make these things work more like "me" and less like "Reddit" which means I need to
do at the very least some fine tuning on the models and I can't really do that with commercial models. 

## Experimental Ideas

### Files for Everything

While containerization is partly to keep the agents from running `rm -fr` because they will absolutely try that someday, it's also about experimenting the different interaction methods. Agents seem to be really good at files
and it's also really easy to build tools that interact with files and file-like things... we've known this for a long time, it's the core principle of UNIX after all. So, maybe lean into that? Containers seem like a convenient
way of introducing virtual filesystems that can do various things that agents already know how to do well. It may also be more token efficient than things like MCP? 

### Lots of Tools

Conversely, agentic harnesses ship with relatively few tools and its pretty hard to add new tools as first class citizens... but maybe it should be more like game engines where you can make little tools for the agent (or they
can make them for each other). Might be fun and if nothing else could be handy for implementing hooks in the agent process.

### Train as you go

Like I said above, I'm interested in making the models work more like me, but I'm also busy so I don't really want to spend a lot of time in some sort of separate training environment. I want to incorporate the process into my tool 
usage as much as I can... I'm sure the commercial models are doing this already since they can see my context... but I want to see if it's possible, at least a little bit, to automate the fine-tuning process beyond simple memory systems
and actually have it become more like me at a fundamental level over time. Not only would that be cool, I've been writing software for a awhile and most of it isn't publicly searchable and therefore not accessible for training. (Nor am I
particularly interested in selling that training data to a large org... that feels like a diminishing returns situation)

## Architecture

Pecan is divided into three main components:

1. **`pecan-server` (The Host Daemon)**
   A persistent gRPC background process that acts as the control plane. It manages agent sessions, owns the connection to LLM providers (e.g., OpenAI, Anthropic, local MLX/llama.cpp models), spawns isolated containers, and proxies all external access (web, HTTP, LLM APIs) on behalf of agents.

2. **`pecan-agent` (The Isolated Worker)**
   The agent process that runs *inside* an Alpine Linux container via Apple's Containerization framework. It has no direct internet access and connects back to the server via a gRPC Unix socket relayed over vsock. All tool execution happens locally inside the container; only LLM completions and external network requests are proxied through the server.

3. **`pecan` (The User Interface)**
   A Terminal User Interface (TUI) with markdown rendering, syntax highlighting, box-drawn tables, and a status chrome bar showing agent names and activity. Connects to the server via gRPC to start sessions, monitor progress, and provide Human-in-the-Loop (HITL) approvals.

## Key Features

- **Containerized Execution:** Agents run inside ephemeral Alpine 3.19 VMs via Apple's Containerization framework (macOS 15+). Each session gets its own isolated container with 2 CPUs and 512MB RAM.
- **gRPC Control Plane:** Bidirectional streaming between UI, server, and agent. The server acts as a strict policy engine for all external access.
- **Centralized Context:** The server holds and manages conversation context in per-session SQLite databases, minimizing data serialized across the VM boundary.
- **Pluggable LLMs:** Configurable to talk to any OpenAI-compatible API endpoint -- local vLLM/MLX servers, commercial providers, or anything else that speaks the OpenAI protocol.
- **Persistent Sessions:** Sessions persist across restarts at `~/.pecan/sessions/`, with workspace directories mounted into containers.

## Built-in Tools

The agent ships with a comprehensive tool suite, organized by tag:

| Tag | Tools | Description |
|-----|-------|-------------|
| **core** | `read_file`, `write_file`, `edit_file`, `search_files`, `shell` | File operations and command execution |
| **web** | `web_fetch`, `web_search`, `http_request` | Web access (proxied through server) |
| **tasks** | `task_create`, `task_list`, `task_get`, `task_update`, `task_focus` | Task management with priorities, labels, dependencies |
| **memory** | `memory_add`, `memory_get`, `memory_list`, `memory_search`, `memory_update`, `memory_delete`, `memory_tag`, `memory_untag` | Persistent memories across sessions; tag as `core` for system prompt injection |
| **triggers** | `trigger_create`, `trigger_list`, `trigger_cancel` | Schedule one-shot or repeating instructions |
| **skills** | `activate_skill` | Load Agent Skills instructions into context |
| **meta** | `create_lua_tool` | Dynamically create and register new Lua tools |

## Extensibility

### Lua Tools

User-defined tools live in `~/.pecan/tools/` and are automatically loaded at agent startup. Tools use a **module pattern** -- the Lua script returns a table with metadata and an `execute` function:

```lua
return {
    name = "my_tool",
    description = "Does something useful.",
    schema = '{"type":"object","properties":{"input":{"type":"string"}},"required":["input"]}',

    execute = function(args)
        return "Result: " .. args.input
    end,

    -- Optional: format the result for compact UI display
    format_result = function(result)
        return "OK"
    end
}
```

Tools can also be created dynamically at runtime via the `create_lua_tool` built-in tool.

### Prompt Fragments

Custom system prompt sections can be added via Lua scripts in `~/.pecan/prompts/`. Each script returns a module with a `render(context)` function:

```lua
return {
    name = "My Custom Instructions",
    priority = 450,  -- lower = earlier in prompt

    render = function(context)
        return "Always prefer tabs over spaces."
    end
}
```

### Hooks

Event-driven Lua scripts in `~/.pecan/hooks/` that fire on agent lifecycle events:

```lua
return {
    on = { "agent.registered", "tool.before", "tool.after", "agent.shutdown" },

    handler = function(event, data)
        -- React to events
    end
}
```

### Agent Skills

Pecan supports the [Agent Skills](https://agentskills.io) open standard. Skills are folders containing a `SKILL.md` file with YAML frontmatter and optional `scripts/`, `references/`, and `assets/` directories:

```
~/.pecan/skills/
  my-skill/
    SKILL.md          # name + description in YAML frontmatter, instructions in body
    scripts/
      helper.lua      # Lua tools auto-registered from skills
    references/
      api-docs.md
    assets/
      template.json
```

Skills follow **progressive disclosure**: only names and descriptions are loaded at startup. Full instructions are loaded on demand via the `activate_skill` tool. The cross-client convention path `~/.agents/skills/` is also supported.

## Getting Started

### Configuration

Create a configuration file at `~/.pecan/config.yaml`:

```yaml
default_model: qwen3
models:
  qwen3:
    name: qwen3
    provider: openai
    url: 'http://localhost:8000'
    api_key: none
    model_id: Qwen/Qwen3-Coder-Next-FP8
```

### Building

Build the server and cross-compile the agent for the container:

```bash
swift build --product pecan-server
swift build -c release --product pecan-agent --swift-sdk aarch64-swift-linux-musl
```

The container mounts `.build/aarch64-swift-linux-musl/release/` at `/opt/pecan`, so no image rebuild is needed after recompiling the agent.

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

### Container Requirements

- macOS 15.0+ (for Apple Containerization framework)
- An uncompressed Linux kernel at `~/.pecan/vm/vmlinux` or installed via `container system kernel set --recommended`
- Swift cross-compilation SDK: `aarch64-swift-linux-musl`

## Documentation

See [DESIGN.md](DESIGN.md) for deeper architectural details.
