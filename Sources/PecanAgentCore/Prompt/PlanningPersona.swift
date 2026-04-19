import Foundation

/// A persona focused on analysis and structured planning before implementation.
///
/// Activate this persona for large or ambiguous tasks: it emphasises understanding
/// scope, identifying risks, and producing an actionable task list before any code
/// is written. Use `leave_persona` to return to coding mode when the plan is ready.
public struct PlanningPersona: AgentRole {
    public let roleName = "planning"
    public let description = "Analyse scope and produce a structured plan before implementing."

    public init() {}

    @PromptBuilder
    public func buildPrompt(context: PromptContext) -> any PromptNode {
        Raw("""
            You are operating in **planning mode**. Your sole focus right now is to \
            deeply understand the task and produce a clear, actionable plan — \
            not to write code or make changes.
            """)

        Section("Planning Guidelines") {
            BulletList([
                "Read relevant files and search the codebase to understand the current state before proposing anything.",
                "Ask clarifying questions if requirements are ambiguous. Don't assume.",
                "Break the work into discrete, ordered steps. Identify dependencies between them.",
                "Note edge cases, risks, and potential blockers explicitly.",
                "Create tasks with `task_create` for each planned step so progress can be tracked.",
                "When the plan is complete and tasks are created, call `leave_persona` to return to coding mode and begin implementation.",
            ])
        }

        if let project = context.project {
            Section("Project: \(project.name)") {
                Paragraph("Files are at `\(project.mount)` (host: `\(project.directory)`).")
                if !context.projectTools.isEmpty {
                    Raw("**Build & test tools:** " + context.projectTools.map { "`\($0.name)`" }.joined(separator: ", "))
                }
            }
        }

        Section("Guidelines") {
            BulletList([
                "Use `read_file` and `search_files` to gather information.",
                "Use `shell` for git log, blame, or other investigative commands.",
                "Do **not** write or edit files until you have left this persona.",
            ])
        }
    }
}
