import Foundation
import Lua

/// Composes the system prompt from a role and optional extension fragments.
/// Manages active tool tags, focused task, and context for the current session.
public actor PromptComposer {
    public static let shared = PromptComposer()

    private var basePersona: (any AgentPersona)?
    private var activePersona: (any AgentPersona)?
    private var fragments: [String: any PromptFragment] = [:]
    private var activeToolTags: Set<String> = ["core", "web", "skills", "meta"]
    private var focusedTask: PromptContext.TaskInfo? = nil
    private var projectInfo: PromptContext.ProjectInfo? = nil
    private var teamInfo: PromptContext.TeamInfo? = nil
    private let pool = LuaStatePool()

    // MARK: - Persona management

    /// Set the long-term base persona for this session.
    public func setBasePersona(_ persona: any AgentPersona) {
        basePersona = persona
    }

    /// Activate a temporary persona, overriding the base for the next `compose` call.
    public func enterPersona(_ persona: any AgentPersona) {
        activePersona = persona
    }

    /// Clear the temporary persona, reverting to the base.
    public func leavePersona() {
        activePersona = nil
    }

    /// The resolved persona: temporary override if set, otherwise the base.
    private var resolvedPersona: (any AgentPersona)? { activePersona ?? basePersona }

    // MARK: - Fragment extensions (e.g. Lua user fragments)

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

    public func setTeamContext(name: String, mount: String) {
        teamInfo = PromptContext.TeamInfo(name: name, mount: mount)
    }

    public func getProjectInfo() -> PromptContext.ProjectInfo? {
        projectInfo
    }

    public func getTeamInfo() -> PromptContext.TeamInfo? {
        teamInfo
    }

    // MARK: - Composition

    /// Compose the full system prompt: role first, then extension fragments in priority order.
    /// All async data (skills, personas, project tools) is pre-fetched into `PromptContext`.
    public func compose(agentID: String, sessionID: String) async -> String {
        // Pre-fetch async data into context
        let rawSkills = await SkillManager.shared.catalog()
        let skillEntries = rawSkills.map { PromptContext.SkillEntry(name: $0.name, description: $0.description) }

        let rawProjectTools = await ToolManager.shared.allToolDescriptions(tags: ["project"])
        let projectToolEntries = rawProjectTools.map { PromptContext.ToolEntry(name: $0.name, description: $0.description) }

        let rawPersonas = await PersonaManager.shared.catalog()
        let personaEntries = rawPersonas.map { PromptContext.PersonaEntry(name: $0.name, description: $0.description) }

        let context = PromptContext(
            activeToolTags: activeToolTags,
            focusedTask: focusedTask,
            agentID: agentID,
            sessionID: sessionID,
            project: projectInfo,
            team: teamInfo,
            skillsCatalog: skillEntries,
            projectTools: projectToolEntries,
            personasCatalog: personaEntries
        )

        var sections: [String] = []

        // Render the resolved persona
        if let persona = resolvedPersona {
            let personaPrompt = persona.render(context: context)
            if !personaPrompt.isEmpty { sections.append(personaPrompt) }
        }

        // Render extension fragments (user Lua fragments, etc.) in priority order
        let sorted = fragments.values.sorted { $0.priority < $1.priority }
        for fragment in sorted {
            let rendered: String?
            if let luaFrag = fragment as? LuaPromptFragment {
                rendered = pool.execute { L in luaFrag.renderSync(context: context, lua: L) }
            } else {
                rendered = await fragment.render(context: context)
            }
            if let text = rendered {
                sections.append(text)
            }
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Setup helpers

    /// Configure this composer with the default coding persona.
    public func useDefaultPersona() {
        setBasePersona(CodingPersona())
    }

    /// Legacy alias for `useDefaultPersona()`.
    public func registerBuiltinFragments() {
        setBasePersona(CodingPersona())
    }

    /// Scan ~/.pecan/prompts/*.lua for user-defined extension fragments.
    public func loadUserFragments() {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let promptsPath = homeDir.appendingPathComponent(".pecan/prompts")

        if !fm.fileExists(atPath: promptsPath.path) {
            try? fm.createDirectory(at: promptsPath, withIntermediateDirectories: true)
        }

        guard let files = try? fm.contentsOfDirectory(atPath: promptsPath.path) else { return }

        for file in files where file.hasSuffix(".lua") {
            let baseName = (file as NSString).deletingPathExtension
            let luaURL = promptsPath.appendingPathComponent(file)

            guard let script = try? String(contentsOf: luaURL, encoding: .utf8) else { continue }
            guard let info = detectLuaPromptModule(script: script, name: baseName) else { continue }

            let fragment = LuaPromptFragment(
                id: "user.\(baseName)",
                name: info.name ?? baseName,
                priority: info.priority ?? 450,
                script: script
            )
            register(fragment: fragment)
        }

        let userCount = fragments.values.filter { $0.id.hasPrefix("user.") }.count
        if userCount > 0 {
            print("[PromptComposer] Loaded \(userCount) user prompt fragment(s)")
        }
    }

}

// MARK: - LuaPromptFragment

/// A user-defined prompt fragment backed by a Lua script.
public struct LuaPromptFragment: PromptFragment, Sendable {
    public let id: String
    public let name: String
    public let priority: Int
    private let script: String

    init(id: String, name: String, priority: Int, script: String) {
        self.id = id
        self.name = name
        self.priority = priority
        self.script = script
    }

    /// Render using a provided (pooled) LuaState. Stack must be clean on entry;
    /// caller resets the stack after this returns.
    func renderSync(context: PromptContext, lua L: LuaState) -> String? {
        do {
            try L.load(string: script, name: name)
            try L.pcall(nargs: 0, nret: 1)

            guard L.type(-1) == .table else { return nil }

            L.push("render")
            L.rawget(-2)
            guard L.type(-1) == .function else { return nil }

            L.newtable()

            L.push("agent_id")
            L.push(context.agentID)
            L.rawset(-3)

            L.push("session_id")
            L.push(context.sessionID)
            L.rawset(-3)

            if let task = context.focusedTask {
                L.push("focused_task_id")
                L.push(task.id)
                L.rawset(-3)

                L.push("focused_task_title")
                L.push(task.title)
                L.rawset(-3)
            }

            try L.pcall(nargs: 1, nret: 1)

            return L.tostring(-1)
        } catch {
            print("[LuaPromptFragment] Error rendering '\(name)': \(error)")
            return nil
        }
    }

    /// PromptFragment protocol conformance — creates its own LuaState (used when no pool available).
    public func render(context: PromptContext) async -> String? {
        let L = LuaState(libraries: .all)
        defer { L.close() }
        return renderSync(context: context, lua: L)
    }
}
