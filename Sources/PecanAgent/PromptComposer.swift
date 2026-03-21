import Foundation
import Lua

/// Composes the system prompt from independent fragments and manages active tool tags.
public actor PromptComposer {
    public static let shared = PromptComposer()

    private var fragments: [String: any PromptFragment] = [:]
    private var activeToolTags: Set<String> = ["core", "tasks", "web", "triggers", "skills"]
    private var focusedTask: PromptContext.TaskInfo? = nil
    private var projectInfo: PromptContext.ProjectInfo? = nil
    private var teamInfo: PromptContext.TeamInfo? = nil

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
            if let rendered = await fragment.render(context: context) {
                sections.append(rendered)
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
        register(fragment: ToolSummaryFragment())
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

    // MARK: - Lua Module Detection

    private struct LuaPromptModuleInfo {
        var name: String?
        var priority: Int?
    }

    private func detectLuaPromptModule(script: String, name: String) -> LuaPromptModuleInfo? {
        let L = LuaState(libraries: .all)
        defer { L.close() }

        do {
            try L.load(string: script, name: name)
            try L.pcall(nargs: 0, nret: 1)
        } catch {
            return nil
        }

        guard L.type(-1) == .table else { return nil }

        // Must have "render" function
        L.push("render")
        L.rawget(-2)
        let hasRender = L.type(-1) == .function
        L.pop(1)
        guard hasRender else { return nil }

        var info = LuaPromptModuleInfo()

        L.push("name")
        L.rawget(-2)
        if let n = L.tostring(-1) { info.name = n }
        L.pop(1)

        L.push("priority")
        L.rawget(-2)
        if let p = L.tointeger(-1) { info.priority = Int(p) }
        L.pop(1)

        return info
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

    public func render(context: PromptContext) async -> String? {
        let scriptStr = self.script
        let nameStr = self.name

        let L = LuaState(libraries: .all)
        defer { L.close() }

        do {
            try L.load(string: scriptStr, name: nameStr)
            try L.pcall(nargs: 0, nret: 1)

            guard L.type(-1) == .table else { return nil }

            L.push("render")
            L.rawget(-2)
            guard L.type(-1) == .function else { return nil }

            // Push context table
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
            print("[LuaPromptFragment] Error rendering '\(nameStr)': \(error)")
            return nil
        }
    }
}
