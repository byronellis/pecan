import Foundation

// MARK: - AgentRole

/// Defines an agent's identity and behavior through a composable prompt.
/// Roles are assigned to teams; the default role is `CodingRole`.
public protocol AgentRole: Sendable {
    /// Short name identifying this role, e.g. `"coding"`.
    var roleName: String { get }

    /// One-line description shown in persona/role catalogs.
    var description: String { get }

    /// Builds the system prompt for this role given the current session context.
    @PromptBuilder
    func buildPrompt(context: PromptContext) -> any PromptNode
}

extension AgentRole {
    /// Default description falls back to the role name.
    public var description: String { roleName }

    /// Renders the role's prompt to a Markdown string.
    public func render(context: PromptContext) -> String {
        buildPrompt(context: context).render()
    }
}

// MARK: - SubagentRole

/// A role for a focused subagent that performs a bounded task and returns a summary.
/// Subagents run with a subset of tools and their own isolated context window.
public protocol SubagentRole: AgentRole {
    /// Tool tags this subagent is allowed to use.
    var allowedToolTags: Set<String> { get }

    /// Builds a task-scoped prompt injected at the start of the subagent's context.
    @PromptBuilder
    func buildTaskPrompt(task: String, context: PromptContext) -> any PromptNode
}
