# Pecan Agent Harness

It was time for a bit of an update with Pecan. I still think the original intent of isolated containers is a good one but ultimately I think the project suffered by trying to do three things:
1. An LLM Proxy. This was sort of necessary in the way Pecan was originally designed since the proxy was actually a UNIX socket to HTTPS proxy. 
1. An agent harness. Again, sort of necessary because no excisting harness really understands communicating over UNIX sockets.
1. A containerization muxer. With each agent operating in its own container I had to implement a way of managing those containers.

While I think a container muxer is a cool idea, it doesn't really go with the proxy or the agent other than the fact that to use containers I needed to do that. So, I'm getting rid of the containerization idea. I still think a container muxer is a cool idea, but I think it's something separate and standalone that doesn't necessarily have anything to do with Agents at all. It'd probably also be better suited to integrating with the rest of Apple's container ecosystem which is getting better with macOS 27 so perhaps another project that does that will arise. 

## A FoundationModels Harness

So Pecan is no longer a containerized harness. It's a harness built on the model frameworks that arrived in macOS 27: FoundationModels and CoreAI. Apple ships a CLI for these (`fm`), but it's pretty primitive and only has a couple of very basic tools. Pecan aims to be the full harness on top of them. Where something does need isolation, like running a risky tool, that's a job for Apple's `container` rather than something Pecan manages itself.

The models come in roughly this order:
1. The on-device system model (`SystemLanguageModel`). This works today.
1. Private Cloud Compute, which is essentially also a system model.
1. Local `.aimodel` models through CoreAI, with MLX alongside for local models and small decision models that handle routing and handoffs.
1. Remote models, starting with OpenAI-compatible APIs.

The question I want Pecan to answer is how cheaply we can run and still get results that are good enough and fast enough. That means deliberately small contexts, even when bigger windows are available, and long chains of work handed off between sessions. Sessions form trees: a main session, sub-sessions that start clean, do a bounded piece of work and report a summary back, forks that branch a conversation, and side conversations for asides. There are no named agents or teams.

There's one `pecan` binary. Running it connects to a resident server (starting it, or upgrading it if this build is newer) that owns the sessions, so the terminal UI and a future SwiftUI app share one backend. The terminal UI is deliberately minimal, along the lines of `fm chat`: output goes into the terminal's own scrollback, and there's a rounded input box at the bottom.

```
make            # versioned dev build (see CLAUDE.md)
pecan           # interactive chat
pecan "hello"   # one-shot answer; also reads piped input
```

## The Proxy

I was going to keep the LLM proxy, but it doesn't fit the new direction either, so it's gone too. Pecan talks to models through FoundationModels, and remote models will come in as model providers inside the harness rather than through a separate router.

## The Agent

Now I could use Claude Code with my proxy and at various points I probably well if for no other reason than to see how it performs vs my own agent harness. That said, even with the harnesses I do use (all of them) I end up wrapping them more often than not. The wrappers I've built so far are pretty complicated things with all sorts of bells and whistles, but I think in a TUI harness you could actually strip things down and implement the style I tend to favor there in a much simpler UI than the ones I've been writing so far. 

Pecan is where we're going to explore that idea. In particular, my other harnesses (none of which are publicly available at the moment) operate in this kind of cross between Gmail and Slack where I have long running threads with the agent. In a lot of ways its similar to a session where the agent dispatches all its work to a subagent and then just reports back the summaries. I got to thinking, well, we could just actually do that and then we'd have something that acts more or less like the session mode we're used to but keeps the handoff-based nature of my preferred work style.
