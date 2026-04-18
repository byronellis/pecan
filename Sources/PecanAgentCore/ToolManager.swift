import Foundation
import PecanShared
import Lua

public protocol PecanTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parametersJSONSchema: String { get }
    var tags: Set<String> { get }

    func execute(argumentsJSON: String) async throws -> String
    func formatResult(_ result: String) -> String?
}

extension PecanTool {
    public func formatResult(_ result: String) -> String? { return nil }
    public var tags: Set<String> { ["core"] }
}

public actor ToolManager {
    public static let shared = ToolManager()
    
    private var tools: [String: PecanTool] = [:]
    
    public init() {}
    
    public func register(tool: PecanTool) {
        tools[tool.name] = tool
    }
    
    public func executeTool(name: String, argumentsJSON: String) async throws -> String {
        guard let tool = tools[name] else {
            throw NSError(domain: "ToolManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Tool '\(name)' not found."])
        }
        return try await tool.execute(argumentsJSON: argumentsJSON)
    }
    
    public func getToolDefinitions(tags: Set<String>? = nil) throws -> Data {
        var definitions: [[String: Any]] = []
        for (_, tool) in tools {
            if let tags = tags, tool.tags.isDisjoint(with: tags) {
                continue
            }
            var def: [String: Any] = [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description
                ]
            ]

            if let schemaData = tool.parametersJSONSchema.data(using: .utf8),
               let schemaObj = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any] {
                var funcDict = def["function"] as! [String: Any]
                funcDict["parameters"] = schemaObj
                def["function"] = funcDict
            }
            definitions.append(def)
        }
        return try JSONSerialization.data(withJSONObject: definitions)
    }
    
    public func registerBuiltinTools() {
        register(tool: ReadFileTool())
        register(tool: WriteFileTool())
        register(tool: AppendFileTool())
        register(tool: EditFileTool())
        register(tool: SearchFilesTool())
        register(tool: BashTool())
        register(tool: WebFetchTool())
        register(tool: WebSearchTool())
        register(tool: HttpRequestTool())
        register(tool: TaskCreateTool())
        register(tool: TaskListTool())
        register(tool: TaskGetTool())
        register(tool: TaskUpdateTool())
        register(tool: TaskFocusTool())
        // Trigger tools
        register(tool: TriggerCreateTool())
        register(tool: TriggerListTool())
        register(tool: TriggerCancelTool())
        // Skills tools
        register(tool: ActivateSkillTool())
    }

    public func formatToolResult(name: String, result: String) -> String? {
        tools[name]?.formatResult(result)
    }

    public func allToolDescriptions(tags: Set<String>? = nil) -> [(name: String, description: String)] {
        tools.values
            .filter { tool in
                guard let tags = tags else { return true }
                return !tool.tags.isDisjoint(with: tags)
            }
            .map { (name: $0.name, description: $0.description) }
            .sorted { $0.name < $1.name }
    }

    public func loadTools() {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let toolsPath = homeDir.appendingPathComponent(".pecan/tools")

        if !fm.fileExists(atPath: toolsPath.path) {
            try? fm.createDirectory(at: toolsPath, withIntermediateDirectories: true)
        }

        guard let files = try? fm.contentsOfDirectory(atPath: toolsPath.path) else { return }

        for file in files where file.hasSuffix(".lua") {
            let fileBaseName = (file as NSString).deletingPathExtension
            let luaURL = toolsPath.appendingPathComponent(file)
            let jsonURL = toolsPath.appendingPathComponent("\(fileBaseName).json")

            guard let script = try? String(contentsOf: luaURL, encoding: .utf8) else { continue }

            // Try to detect module pattern by running the script and checking the return type
            if let moduleInfo = detectLuaModule(script: script, fallbackName: fileBaseName) {
                // Module-style tool: metadata from the module table itself
                let toolName = moduleInfo.name ?? fileBaseName
                let toolDesc = moduleInfo.description ?? "A Lua tool."
                let toolSchema = moduleInfo.schema ?? "{\"type\":\"object\",\"properties\":{}}"

                let tool = LuaTool(name: toolName, description: toolDesc, parametersJSONSchema: toolSchema, mode: .module(script: script))
                register(tool: tool)
            } else if let schemaJSON = try? String(contentsOf: jsonURL, encoding: .utf8) {
                // Legacy function-style with JSON sidecar
                var description = "A Lua tool."
                if let data = schemaJSON.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let desc = obj["description"] as? String {
                    description = desc
                }

                let tool = LuaTool(name: fileBaseName, description: description, parametersJSONSchema: schemaJSON, script: script)
                register(tool: tool)
            }
            // If neither module nor sidecar JSON, skip the file
        }
    }

}
