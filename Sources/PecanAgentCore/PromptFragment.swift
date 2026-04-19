import Foundation

/// A composable piece of the system prompt. Fragments are sorted by priority
/// and rendered in order to build the final prompt.
public protocol PromptFragment: Sendable {
    var id: String { get }
    var name: String { get }
    var priority: Int { get }  // lower = earlier in prompt
    func render(context: PromptContext) async -> String?  // nil = omit
}

/// Context passed to each fragment and role during rendering.
/// All async data (skills catalog, etc.) is pre-fetched before construction.
public struct PromptContext: Sendable {
    public let activeToolTags: Set<String>
    public let focusedTask: TaskInfo?
    public let agentID: String
    public let sessionID: String
    public let project: ProjectInfo?
    public let team: TeamInfo?
    public let skillsCatalog: [SkillEntry]
    /// Project-scoped build/test tools available in this session (empty if no project context).
    public let projectTools: [ToolEntry]
    /// Available personas the agent can activate (empty for subagents).
    public let personasCatalog: [PersonaEntry]

    public init(
        activeToolTags: Set<String>,
        focusedTask: TaskInfo?,
        agentID: String,
        sessionID: String,
        project: ProjectInfo?,
        team: TeamInfo?,
        skillsCatalog: [SkillEntry] = [],
        projectTools: [ToolEntry] = [],
        personasCatalog: [PersonaEntry] = []
    ) {
        self.activeToolTags = activeToolTags
        self.focusedTask = focusedTask
        self.agentID = agentID
        self.sessionID = sessionID
        self.project = project
        self.team = team
        self.skillsCatalog = skillsCatalog
        self.projectTools = projectTools
        self.personasCatalog = personasCatalog
    }

    public struct TaskInfo: Sendable {
        public let id: Int
        public let title: String
        public let description: String
        public let status: String
    }

    public struct ProjectInfo: Sendable {
        public let name: String
        public let directory: String   // host directory
        public let mount: String       // guest mount path (e.g. "/project")
    }

    public struct TeamInfo: Sendable {
        public let name: String
        public let mount: String       // guest mount path (e.g. "/team")
    }

    public struct SkillEntry: Sendable {
        public let name: String
        public let description: String

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    public struct ToolEntry: Sendable {
        public let name: String
        public let description: String

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    public struct PersonaEntry: Sendable {
        public let name: String
        public let description: String

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }
}
