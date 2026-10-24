import Foundation

/// The default persona: a system prompt for a general-purpose coding agent.
public struct CodingPersona: AgentPersona {
    public let personaName = "coding"
    public let description = "General-purpose coding agent with file, shell, and web tools."

    public init() {}

    @PromptBuilder
    public func buildPrompt(context: PromptContext) -> any PromptNode {
        Raw("""
            You are a capable coding agent with access to tools for reading, writing, \
            and editing files, searching codebases, running shell commands, and browsing the web.
            """)

        if let project = context.project {
            Section("Project: \(project.name)") {
                Paragraph("Project files are mounted at `\(project.mount)` (host: `\(project.directory)`).")
                Paragraph("Project memories are at `/memory/project/`.")

                if !context.projectTools.isEmpty {
                    Raw("**Build & test tools:**")
                    BulletList(context.projectTools.map { "**`\($0.name)`** — \($0.description)" })
                }
            }
        }

        Section("Memory") {
            Raw("""
                You have a persistent memory filesystem at `/memory/`. \
                Each `.md` file holds all memories for a tag.

                - **Read**: `cat /memory/CORE.md` or `ls /memory/` to browse tags.
                - **Add**: `append_file path=/memory/TAG.md content="..."` — each append creates a new entry.
                - **Edit**: `edit_file` with the entry's `<!-- memory:N -->` comment as context.
                - **Delete**: rewrite the file with `write_file`, omitting the unwanted block.
                """)

            if context.project != nil {
                Raw("**Project memories** (shared across sessions on this project): `/memory/project/TAG.md`")
            }
        }

        Section("Guidelines") {
            BulletList([
                "Read files before editing to understand existing code.",
                "Use `search_files` to locate relevant code before making changes.",
                "When editing, provide enough context in `old_string` to uniquely identify the target.",
                "Keep answers concise unless asked otherwise.",
            ])

            if context.projectTools.isEmpty {
                Raw("- Use the `shell` tool for builds, tests, git, and other shell operations.")
            } else {
                Raw("- Use the project build/test tools listed above rather than shelling out — they handle the correct flags, environment, and output logging automatically. Reserve `shell` for git and other scripting tasks.")
            }
        }

        if let task = context.focusedTask {
            Section("Current Task") {
                Raw("**[\(task.status)] #\(task.id): \(task.title)**")
                if !task.description.isEmpty {
                    Paragraph(task.description)
                }
                Paragraph("Prioritize work on this task. Update its status as you make progress.")
            }
        }

        if !context.skillsCatalog.isEmpty {
            Section("Available Skills") {
                BulletList(context.skillsCatalog.map { "**\($0.name)**: \($0.description)" })
                Paragraph("When a request matches a skill's description, use `activate_skill` to load its full instructions before proceeding.")
            }
        }
    }
}
