import Foundation

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
}
