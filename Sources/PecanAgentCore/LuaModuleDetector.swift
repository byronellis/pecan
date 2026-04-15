import Lua

// MARK: - Shared Lua module detection

/// Metadata extracted from a Lua module table.
struct LuaModuleInfo {
    var name: String?
    var description: String?
    var schema: String?
}

/// Metadata extracted from a Lua prompt-fragment module table.
struct LuaPromptModuleInfo {
    var name: String?
    var priority: Int?
}

/// Detect whether a Lua script returns a module table with an `execute` function.
/// Returns metadata extracted from the table, or nil if it's not a module.
func detectLuaModule(script: String, fallbackName: String) -> LuaModuleInfo? {
    let L = LuaState(libraries: .all)
    defer { L.close() }

    do {
        try L.load(string: script, name: fallbackName)
        try L.pcall(nargs: 0, nret: 1)
    } catch {
        return nil
    }

    guard L.type(-1) == .table else { return nil }

    // Must have "execute" function
    L.push("execute")
    L.rawget(-2)
    let hasExecute = L.type(-1) == .function
    L.pop(1)
    guard hasExecute else { return nil }

    var info = LuaModuleInfo()

    L.push("name")
    L.rawget(-2)
    if let n = L.tostring(-1) { info.name = n }
    L.pop(1)

    L.push("description")
    L.rawget(-2)
    if let d = L.tostring(-1) { info.description = d }
    L.pop(1)

    L.push("schema")
    L.rawget(-2)
    if let s = L.tostring(-1) { info.schema = s }
    L.pop(1)

    return info
}

/// Detect whether a Lua script returns a prompt-fragment module table with a `render` function.
/// Returns metadata extracted from the table, or nil if it's not a prompt module.
func detectLuaPromptModule(script: String, name: String) -> LuaPromptModuleInfo? {
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
