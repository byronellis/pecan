import Foundation

/// A persona focused on delegating work to specialized subagents.
public struct CoordinatorPersona: AgentPersona {
    public let personaName = "coordinator"
    public let description = "Coordinate tasks by delegating them to specialized subagents."

    public init() {}

    @PromptBuilder
    public func buildPrompt(context: PromptContext) -> any PromptNode {
        Raw("""
            You are operating in **coordinator mode**. Your primary role is to \
            analyze complex instructions, decompose them, and coordinate execution \
            by delegating tasks to specialized subagents and tools.
            """)

        Section("Coordination Guidelines") {
            BulletList([
                "Define clear, bounded tasks for subagents using `define_subagent` if none exist.",
                "Invoke subagents using `invoke_subagent` with explicit tasks and retrieve their results.",
                "Consolidate responses from subagents and review them for correctness.",
                "Communicate progress to the user, acting as the team manager.",
            ])
        }

        if let project = context.project {
            Section("Project: \(project.name)") {
                Paragraph("Shared project workspace is at `\(project.mount)`.")
            }
        }
    }
}
