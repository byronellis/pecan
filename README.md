# Pecan: Persistent Extensible Containerized AgeNts

Yeah, the name is a bit of a stretch, but I'm fine with that. Pecan is an experimental agentic coding harness intended more as an exploration of different ideas in the space rather than simply copying whatever it happens to be that 
Claude Code is doing this week. Which isn't a knock on Claude Code, I use it and it's pretty good. But these harnesses introduce quite a bit of pre- and post- processing and other assumptions so at the end of the day it's still 
really about how Anthropic things I should code, not necessarily how I code (for whatever value of code we're going with these days). 

Or it could just be what a friend of mine said the other day when I was showing him the very very beginning of the project: "This is like a Jedi thing isn't it?" And, yeah, maybe it is. Anyway, I wanted to do it and so I'm doing it.

## Questions You Might Have

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
    url: 'http://localhost:8000'
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
