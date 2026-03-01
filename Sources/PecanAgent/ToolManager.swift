import Foundation
import PecanShared
import Lua

public protocol PecanTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parametersJSONSchema: String { get }
    
    func execute(argumentsJSON: String) async throws -> String
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
    
    public func getToolDefinitions() throws -> Data {
        var definitions: [[String: Any]] = []
        for (_, tool) in tools {
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
    
    public func loadTools() {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let toolsPath = homeDir.appendingPathComponent(".pecan/tools")
        
        if !fm.fileExists(atPath: toolsPath.path) {
            try? fm.createDirectory(at: toolsPath, withIntermediateDirectories: true)
        }
        
        guard let files = try? fm.contentsOfDirectory(atPath: toolsPath.path) else { return }
        
        for file in files where file.hasSuffix(".lua") {
            let name = (file as NSString).deletingPathExtension
            let luaURL = toolsPath.appendingPathComponent(file)
            let jsonURL = toolsPath.appendingPathComponent("\(name).json")
            
            if let script = try? String(contentsOf: luaURL, encoding: .utf8),
               let schemaJSON = try? String(contentsOf: jsonURL, encoding: .utf8) {
                
                // Extract description from JSON schema (or default it)
                var description = "A Lua tool."
                if let data = schemaJSON.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let desc = obj["description"] as? String {
                    description = desc
                }
                
                let tool = LuaTool(name: name, description: description, parametersJSONSchema: schemaJSON, script: script)
                register(tool: tool)
            }
        }
    }
}
