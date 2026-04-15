import Foundation

/// Groups the injectable dependencies for AgentEventHandler.
/// Use `.shared` for production; supply fresh instances in tests.
public struct AgentDependencies: Sendable {
    public let toolManager: ToolManager
    public let promptComposer: PromptComposer
    public let hookManager: HookManager

    public static let shared = AgentDependencies(
        toolManager: .shared,
        promptComposer: .shared,
        hookManager: .shared
    )

    public init(
        toolManager: ToolManager = .shared,
        promptComposer: PromptComposer = .shared,
        hookManager: HookManager = .shared
    ) {
        self.toolManager = toolManager
        self.promptComposer = promptComposer
        self.hookManager = hookManager
    }
}
