import Foundation
import Lua

/// A cached, reusable Lua execution environment for use within a single-actor context.
/// Not thread-safe — the owning actor is responsible for ensuring no concurrent access.
final class LuaStatePool: @unchecked Sendable {
    private let state: LuaState

    init() {
        state = LuaState(libraries: .all)
    }

    deinit {
        state.close()
    }

    /// Execute `body` with a clean-stack Lua state.
    /// The stack is reset to 0 before and after `body` runs.
    @discardableResult
    func execute<T>(_ body: (LuaState) throws -> T) rethrows -> T {
        state.settop(0)
        defer { state.settop(0) }
        return try body(state)
    }
}
