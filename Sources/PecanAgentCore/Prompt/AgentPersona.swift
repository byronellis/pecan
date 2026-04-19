import Foundation

// MARK: - AgentPersona

/// Defines an agent's identity and behavior through a composable prompt.
/// The default persona is `CodingPersona`.
public protocol AgentPersona: Sendable {
    /// Short name identifying this persona, e.g. `"coding"`.
    var personaName: String { get }

    /// One-line description shown in persona catalogs.
    var description: String { get }

    /// Builds the system prompt for this persona given the current session context.
    @PromptBuilder
    func buildPrompt(context: PromptContext) -> any PromptNode
}

extension AgentPersona {
    /// Default description falls back to the persona name.
    public var description: String { personaName }

    /// Renders the persona's prompt to a Markdown string.
    public func render(context: PromptContext) -> String {
        buildPrompt(context: context).render()
    }
}

// MARK: - SubagentPersona

/// A persona for a focused subagent that performs a bounded task and returns a summary.
/// Subagents run with a subset of tools and their own isolated context window.
public protocol SubagentPersona: AgentPersona {
    /// Tool tags this subagent is allowed to use.
    var allowedToolTags: Set<String> { get }

    /// Builds a task-scoped prompt injected at the start of the subagent's context.
    @PromptBuilder
    func buildTaskPrompt(task: String, context: PromptContext) -> any PromptNode
}
