import Foundation
import PecanShared
import Lua

public enum LuaToolMode: Sendable {
    case legacyFunction(script: String)
    case module(script: String)  // has execute, maybe format_result
}

public struct LuaTool: PecanTool, Sendable {
    public let name: String
    public let description: String
    public let parametersJSONSchema: String

    private let mode: LuaToolMode

    public init(name: String, description: String, parametersJSONSchema: String, script: String) {
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
        self.mode = .legacyFunction(script: script)
    }

    public init(name: String, description: String, parametersJSONSchema: String, mode: LuaToolMode) {
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
        self.mode = mode
    }

    private var script: String {
        switch mode {
        case .legacyFunction(let s), .module(let s): return s
        }
    }

    /// Push arguments table onto the Lua stack.
    private static func pushArguments(_ L: LuaState, json: String) -> CInt {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 0
        }
        L.newtable()
        for (key, value) in dict {
            L.push(key)
            switch value {
            case let v as String:  L.push(v)
            case let v as Int:     L.push(v)
            case let v as Double:  L.push(v)
            case let v as Bool:    L.push(v)
            default:
                if let nestedData = try? JSONSerialization.data(withJSONObject: value),
                   let nestedStr = String(data: nestedData, encoding: .utf8) {
                    L.push(nestedStr)
                } else {
                    L.pushnil()
                }
            }
            L.rawset(-3)
        }
        return 1
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let scriptStr = self.script
        let args = argumentsJSON
        let nameStr = self.name
        let isModule = if case .module = self.mode { true } else { false }

        let handle = Task.detached {
            let L = LuaState(libraries: .all)
            defer { L.close() }

            try L.load(string: scriptStr, name: nameStr)

            if isModule {
                // Execute the script to get the module table
                try L.pcall(nargs: 0, nret: 1)
                // Stack: module table
                // Get "execute" function from the table
                L.push("execute")
                L.rawget(-2) // stack: module_table, execute_fn
                let argCount = LuaTool.pushArguments(L, json: args)
                try L.pcall(nargs: argCount, nret: 1)
            } else {
                // Legacy: script returns a function, call it with args
                let argCount = LuaTool.pushArguments(L, json: args)
                try L.pcall(nargs: argCount, nret: 1)
            }

            if let result = L.tostring(-1) {
                return result
            } else {
                return "Tool executed successfully but returned no string value."
            }
        }

        return try await handle.value
    }

    public func formatResult(_ result: String) -> String? {
        guard case .module(let scriptStr) = self.mode else { return nil }

        let resultStr = result
        let nameStr = self.name

        // Run inline — formatResult is sync per protocol, and Lua execution is fast
        let L = LuaState(libraries: .all)
        defer { L.close() }

        do {
            try L.load(string: scriptStr, name: nameStr)
            try L.pcall(nargs: 0, nret: 1)

            L.push("format_result")
            L.rawget(-2)
            guard L.type(-1) == .function else { return nil }

            L.push(resultStr)
            try L.pcall(nargs: 1, nret: 1)

            return L.tostring(-1)
        } catch {
            return nil
        }
    }
}
