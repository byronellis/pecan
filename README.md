# Pecan Agent Harness

It was time for a bit of an update with Pecan. I still think the original intent of isolated containers is a good one but ultimately I think the project suffered by trying to do three things:
1. An LLM Proxy. This was sort of necessary in the way Pecan was originally designed since the proxy was actually a UNIX socket to HTTPS proxy. 
1. An agent harness. Again, sort of necessary because no excisting harness really understands communicating over UNIX sockets.
1. A containerization muxer. With each agent operating in its own container I had to implement a way of managing those containers.

While I think a container muxer is a cool idea, it doesn't really go with the proxy or the agent other than the fact that to use containers I needed to do that. So, I'm getting rid of the containerization idea. I still think a container muxer is a cool idea, but I think it's something separate and standalone that doesn't necessarily have anything to do with Agents at all. It'd probably also be better suited to integrating with the rest of Apple's container ecosystem which is getting better with macOS 27 so perhaps another project that does that will arise. 

## The Proxy

These days I've got a bunch of different accounts at a bunch of different services including The Big 3, though those are mostly subscription accounts (until that goes away, but this is relevant). I've also got truly local models and a server at home that also runs one of several different models at any given time. As predicted people decided they wanted yachts so prices are going up and everyone is trying to optimize for, basically, ROI one way or another. So it makes sense to build out the proxy and while there are a bunch out there I wanted to keep doing my own. So I'm keeping that bit.

I do want it to also be a standalone router so it can be used standalone and not with the Pecan agent. It should speak both OpenAI and Anthropic so that should mean it can act as a router for Claude Code and Codex and other harnesses. It also supports local MLX so it also acts as something of a server in its own right.

## The Agent

Now I could use Claude Code with my proxy and at various points I probably well if for no other reason than to see how it performs vs my own agent harness. That said, even with the harnesses I do use (all of them) I end up wrapping them more often than not. The wrappers I've built so far are pretty complicated things with all sorts of bells and whistles, but I think in a TUI harness you could actually strip things down and implement the style I tend to favor there in a much simpler UI than the ones I've been writing so far. 

Pecan is where we're going to explore that idea. In particular, my other harnesses (none of which are publicly available at the moment) operate in this kind of cross between Gmail and Slack where I have long running threads with the agent. In a lot of ways its similar to a session where the agent dispatches all its work to a subagent and then just reports back the summaries. I got to thinking, well, we could just actually do that and then we'd have something that acts more or less like the session mode we're used to but keeps the handoff-based nature of my preferred work style. 




## Documentation

See [DESIGN.md](DESIGN.md) for deeper architectural details.
