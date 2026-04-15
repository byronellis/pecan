import Foundation
import Lua

struct LuaHook: Sendable {
    let name: String
    let events: [String]
    let script: String
}

public actor HookManager {
    public static let shared = HookManager()

    private var hooks: [String: LuaHook] = [:]  // filename -> hook
    private let pool = LuaStatePool()

    public func loadHooks() {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let hooksPath = homeDir.appendingPathComponent(".pecan/hooks")

        if !fm.fileExists(atPath: hooksPath.path) {
            try? fm.createDirectory(at: hooksPath, withIntermediateDirectories: true)
        }

        guard let files = try? fm.contentsOfDirectory(atPath: hooksPath.path) else { return }

        for file in files where file.hasSuffix(".lua") {
            let name = (file as NSString).deletingPathExtension
            let luaURL = hooksPath.appendingPathComponent(file)

            guard let script = try? String(contentsOf: luaURL, encoding: .utf8) else { continue }

            let events = detectHookEvents(script: script, name: name)
            guard !events.isEmpty else { continue }

            hooks[name] = LuaHook(name: name, events: events, script: script)
        }

        if !hooks.isEmpty {
            print("[HookManager] Loaded \(hooks.count) hook(s): \(hooks.keys.sorted().joined(separator: ", "))")
        }
    }

    public func fire(event: String, data: [String: Any]) {
        for (_, hook) in hooks {
            guard hook.events.contains(event) else { continue }
            runHook(hook, event: event, data: data)
        }
    }

    // MARK: - Private execution

    private func runHook(_ hook: LuaHook, event: String, data: [String: Any]) {
        pool.execute { L in
            do {
                try L.load(string: hook.script, name: hook.name)
                try L.pcall(nargs: 0, nret: 1)

                guard L.type(-1) == .table else { return }

                L.push("handler")
                L.rawget(-2)
                guard L.type(-1) == .function else { return }

                L.push(event)

                L.newtable()
                for (key, value) in data {
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

                try L.pcall(nargs: 2, nret: 0)
            } catch {
                print("[HookManager] Error in hook '\(hook.name)' for event '\(event)': \(error)")
            }
        }
    }

    private func detectHookEvents(script: String, name: String) -> [String] {
        pool.execute { L in
            do {
                try L.load(string: script, name: name)
                try L.pcall(nargs: 0, nret: 1)
            } catch {
                print("[HookManager] Failed to load hook '\(name)': \(error)")
                return []
            }

            guard L.type(-1) == .table else { return [] }

            L.push("on")
            L.rawget(-2)
            guard L.type(-1) == .table else { return [] }

            var events: [String] = []
            var i: CInt = 1
            while true {
                L.push(Int(i))
                L.rawget(-2)
                if let s = L.tostring(-1) {
                    events.append(s)
                    L.pop(1)
                    i += 1
                } else {
                    L.pop(1)
                    break
                }
            }

            L.pop(1)  // pop "on" table
            L.push("handler")
            L.rawget(-2)
            let hasHandler = L.type(-1) == .function
            L.pop(1)

            return hasHandler ? events : []
        }
    }
}
