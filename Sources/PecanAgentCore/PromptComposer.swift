import Foundation

/// Composes the system prompt from a persona and optional extension fragments.
/// Manages active tool tags, focused task, and context for the current session.
public actor PromptComposer {
    public static let shared = PromptComposer()

    private var persona: (any AgentPersona)?
    private var fragments: [String: any PromptFragment] = [:]
    private var activeToolTags: Set<String> = ["core", "web", "skills", "meta"]
    private var focusedTask: PromptContext.TaskInfo? = nil
    private var projectInfo: PromptContext.ProjectInfo? = nil

    // MARK: - Persona

    public func setPersona(_ persona: any AgentPersona) {
        self.persona = persona
    }

    // MARK: - Fragment extensions

    public func register(fragment: any PromptFragment) {
        fragments[fragment.id] = fragment
    }

    // MARK: - Context setters

    public func setActiveToolTags(_ tags: Set<String>) {
        activeToolTags = tags
    }

    public func setFocusedTask(_ task: PromptContext.TaskInfo?) {
        focusedTask = task
    }

    public func getActiveToolTags() -> Set<String> {
        activeToolTags
    }

    public func getFocusedTask() -> PromptContext.TaskInfo? {
        focusedTask
    }

    public func setProjectContext(name: String, directory: String, mount: String) {
        projectInfo = PromptContext.ProjectInfo(name: name, directory: directory, mount: mount)
    }

    public func getProjectInfo() -> PromptContext.ProjectInfo? {
        projectInfo
    }

    // MARK: - Composition

    /// Compose the full system prompt: role first, then extension fragments in priority order.
    /// All async data (skills, project tools) is pre-fetched into `PromptContext`.
    public func compose(agentID: String, sessionID: String) async -> String {
        let rawProjectTools = await ToolManager.shared.allToolDescriptions(tags: ["project"])
        let projectToolEntries = rawProjectTools.map { PromptContext.ToolEntry(name: $0.name, description: $0.description) }

        let context = PromptContext(
            activeToolTags: activeToolTags,
            focusedTask: focusedTask,
            agentID: agentID,
            sessionID: sessionID,
            project: projectInfo,
            skillsCatalog: [],
            projectTools: projectToolEntries
        )

        var sections: [String] = []

        if let persona {
            let personaPrompt = persona.render(context: context)
            if !personaPrompt.isEmpty { sections.append(personaPrompt) }
        }

        // Render extension fragments in priority order
        let sorted = fragments.values.sorted { $0.priority < $1.priority }
        for fragment in sorted {
            if let text = await fragment.render(context: context) {
                sections.append(text)
            }
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Setup helpers

    /// Configure this composer with the default coding persona.
    public func useDefaultPersona() {
        setPersona(CodingPersona())
    }
}
