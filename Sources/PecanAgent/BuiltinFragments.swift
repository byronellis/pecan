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
            lines.append("Project memories are at `/memory/project/`.")
        }

        if let team = context.team {
            // Don't show "default" team name
            if team.name != "default" {
                lines.append("## Team: \(team.name)")
            }
            if !team.mount.isEmpty {
                lines.append("Team shared workspace is mounted at `\(team.mount)`.")
            }
            lines.append("Team memories are at `/memory/team/`.")
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
        var lines = [
            "## Memory",
            "You have a persistent memory filesystem at `/memory/`. Each file represents all memories sharing a tag.",
            "Files survive across sessions and are backed by a database.",
            "",
            "**Reading**: `cat /memory/CORE.md`, `ls /memory/`",
            "**Adding a new memory**: `append_file path=/memory/NOTES.md content=\"...\"`",
            "  (appending to a tag file always creates a new memory entry)",
            "**Editing / full replace**: `write_file` with the complete block document — existing `<!-- memory:N -->` IDs are preserved; blocks without IDs are inserted; missing IDs are deleted.",
            "**Core memories** (auto-injected into context at startup): tag `core` → `/memory/CORE.md`",
            "",
            "File format:",
            "```",
            "<!-- memory:1 -->",
            "Content of first memory.",
            "",
            "<!-- memory:2 -->",
            "Content of second memory.",
            "```",
        ]
        if context.project != nil {
            lines.append("")
            lines.append("**Project memories**: `/memory/project/TAG.md` — shared across all agents in this project.")
        }
        if context.team != nil {
            lines.append("**Team memories**: `/memory/team/TAG.md` — shared within the team.")
        }
        return lines.joined(separator: "\n")
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
