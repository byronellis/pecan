import Foundation
import PecanShared
import Lua

public struct LuaTool: PecanTool, Sendable {
    public let name: String
    public let description: String
    public let parametersJSONSchema: String
    
    private let script: String
    
    public init(name: String, description: String, parametersJSONSchema: String, script: String) {
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
        self.script = script
    }
    
    public func execute(argumentsJSON: String) async throws -> String {
        let scriptStr = self.script
        let args = argumentsJSON
        let nameStr = self.name
        
        let handle = Task.detached {
            let L = LuaState(libraries: .all)
            defer { L.close() }
            
            try L.load(string: scriptStr, name: nameStr)
            
            var argCount: CInt = 0
            
            if !args.isEmpty {
                if let data = args.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Push a table
                    L.newtable()
                    for (key, value) in dict {
                        L.push(key)
                        if let vStr = value as? String {
                            L.push(vStr)
                        } else if let vInt = value as? Int {
                            L.push(vInt)
                        } else if let vDouble = value as? Double {
                            L.push(vDouble)
                        } else if let vBool = value as? Bool {
                            L.push(vBool)
                        } else if let nestedData = try? JSONSerialization.data(withJSONObject: value),
                                  let nestedStr = String(data: nestedData, encoding: .utf8) {
                            // Fallback for complex nested objects, pass as JSON string
                            L.push(nestedStr)
                        } else {
                            L.pushnil()
                        }
                        L.rawset(-3)
                    }
                    argCount = 1
                }
            }
            
            try L.pcall(nargs: argCount, nret: 1)
            
            if let result = L.tostring(-1) {
                return result
            } else {
                return "Tool executed successfully but returned no string value."
            }
        }
        
        return try await handle.value
    }
}
