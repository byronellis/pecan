import Foundation
import Lua

/// Composes the system prompt from independent fragments and manages active tool tags.
public actor PromptComposer {
    public static let shared = PromptComposer()

    private var fragments: [String: any PromptFragment] = [:]
    private var activeToolTags: Set<String> = ["core", "web", "skills"]
    private var focusedTask: PromptContext.TaskInfo? = nil
    private var projectInfo: PromptContext.ProjectInfo? = nil
    private var teamInfo: PromptContext.TeamInfo? = nil
    private let pool = LuaStatePool()

    public func register(fragment: any PromptFragment) {
        fragments[fragment.id] = fragment
    }

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

    /// Compose the full system prompt by rendering all fragments in priority order.
    public func compose(agentID: String, sessionID: String) async -> String {
        let context = PromptContext(
            activeToolTags: activeToolTags,
            focusedTask: focusedTask,
            agentID: agentID,
            sessionID: sessionID,
            project: projectInfo,
            team: teamInfo
        )

        let sorted = fragments.values.sorted { $0.priority < $1.priority }
        var sections: [String] = []

        for fragment in sorted {
            let rendered: String?
            if let luaFrag = fragment as? LuaPromptFragment {
                // Reuse the pooled LuaState to avoid per-call init/close overhead.
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

    /// Register all built-in prompt fragments.
    public func registerBuiltinFragments() {
        register(fragment: BaseIdentityFragment())
        register(fragment: ProjectTeamContextFragment())
        register(fragment: GuidelinesFragment())
        register(fragment: MemoryFragment())
        register(fragment: FocusedTaskFragment())
        register(fragment: SkillCatalogFragment())
    }

    /// Scan ~/.pecan/prompts/*.lua for user-defined prompt fragments.
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
