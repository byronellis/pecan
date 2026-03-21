import Foundation
import PecanShared

// MARK: - BaseIdentityFragment (priority 0)

struct BaseIdentityFragment: PromptFragment, Sendable {
    let id = "builtin.identity"
    let name = "Identity"
    let priority = 0

    func render(context: PromptContext) async -> String? {
        "You are a helpful coding assistant with access to tools for reading, writing, editing, and searching files, as well as running shell commands."
    }
}

// MARK: - GuidelinesFragment (priority 100)

struct GuidelinesFragment: PromptFragment, Sendable {
    let id = "builtin.guidelines"
    let name = "Guidelines"
    let priority = 100

    func render(context: PromptContext) async -> String? {
        """
        ## Guidelines
        - Read files before editing them to understand existing code.
        - Use search_files to locate relevant code before making changes.
        - When editing, provide enough context in old_string to uniquely identify the target.
        - Keep your answers concise unless asked otherwise.
        - Use the bash tool for running builds, tests, git commands, and other shell operations.
        """
    }
}

// MARK: - ProjectTeamContextFragment (priority 50)

struct ProjectTeamContextFragment: PromptFragment, Sendable {
    let id = "builtin.project_team"
    let name = "Project & Team Context"
    let priority = 50

    func render(context: PromptContext) async -> String? {
        var lines: [String] = []

        if let project = context.project {
            lines.append("## Project: \(project.name)")
            if !project.directory.isEmpty {
                lines.append("Project directory is mounted at `\(project.mount)` (host: \(project.directory)).")
            }
            lines.append("Use `scope: \"project\"` in task/memory tools to work with project-level data.")
        }

        if let team = context.team {
            // Don't show "default" team name
            if team.name != "default" {
                lines.append("## Team: \(team.name)")
            }
            if !team.mount.isEmpty {
                lines.append("Team shared workspace is mounted at `\(team.mount)`.")
            }
            lines.append("Use `scope: \"team\"` in task/memory tools to work with team-level data.")
        }

        if let project = context.project, let team = context.team {
            lines.append("")
            lines.append("Task and memory listings merge results from all scopes (agent, team, project) by default. Each result includes a `scope` field indicating its origin.")
            _ = project; _ = team  // silence unused warnings
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

// MARK: - MemoryFragment (priority 200)

struct MemoryFragment: PromptFragment, Sendable {
    let id = "builtin.memory"
    let name = "Memory"
    let priority = 200

    func render(context: PromptContext) async -> String? {
        """
        ## Memory
        You have a persistent memory filesystem mounted at `/memory/`. \
        Files here are plain Markdown and survive across sessions.

        **Reading memories**: Use `read_file` or `bash` (`ls /memory/`, `cat /memory/foo.md`).
        **Writing memories**: Use `write_file` or `bash` to create/update `.md` files.
        **Core memories** (auto-injected into your context at startup): name the file `core_<name>.md`.

        Keep memory files focused and well-named. Examples:
        - `/memory/core_preferences.md` — user preferences, always injected
        - `/memory/core_project_context.md` — key project facts, always injected
        - `/memory/notes.md` — scratch notes for the current session
        - `/memory/learnings.md` — things you've discovered about the codebase
        """
    }
}

// MARK: - FocusedTaskFragment (priority 250)

struct FocusedTaskFragment: PromptFragment, Sendable {
    let id = "builtin.focused_task"
    let name = "Focused Task"
    let priority = 250

    func render(context: PromptContext) async -> String? {
        guard let task = context.focusedTask else { return nil }
        return """
        ## Focused Task
        **[\(task.status)] #\(task.id): \(task.title)**
        \(task.description)

        Prioritize work related to this task. Update its status when progress is made.
        """
    }
}

// MARK: - ToolSummaryFragment (priority 300)

struct ToolSummaryFragment: PromptFragment, Sendable {
    let id = "builtin.tool_summary"
    let name = "Tool Summary"
    let priority = 300

    func render(context: PromptContext) async -> String? {
        let tools = await ToolManager.shared.allToolDescriptions(tags: context.activeToolTags)
        guard !tools.isEmpty else { return nil }

        var section = "## Available Tools"
        for tool in tools {
            section += "\n- **\(tool.name)**: \(tool.description)"
        }
        return section
    }
}

// MARK: - SkillCatalogFragment (priority 350)

struct SkillCatalogFragment: PromptFragment, Sendable {
    let id = "builtin.skill_catalog"
    let name = "Skill Catalog"
    let priority = 350

    func render(context: PromptContext) async -> String? {
        let skills = await SkillManager.shared.catalog()
        guard !skills.isEmpty else { return nil }

        var section = "<available_skills>\n"
        for skill in skills {
            section += "  <skill><name>\(skill.name)</name><description>\(skill.description)</description></skill>\n"
        }
        section += "</available_skills>\n\n"
        section += "When a user's request matches a skill's description, use the activate_skill tool to load its full instructions before proceeding."

        return section
    }
}
