import Foundation

/// A composable piece of the system prompt. Fragments are sorted by priority
/// and rendered in order to build the final prompt.
public protocol PromptFragment: Sendable {
    var id: String { get }
    var name: String { get }
    var priority: Int { get }  // lower = earlier in prompt
    func render(context: PromptContext) async -> String?  // nil = omit
}

/// Context passed to each fragment during rendering.
public struct PromptContext: Sendable {
    public let activeToolTags: Set<String>
    public let focusedTask: TaskInfo?
    public let agentID: String
    public let sessionID: String
    public let project: ProjectInfo?
    public let team: TeamInfo?

    public struct TaskInfo: Sendable {
        public let id: Int
        public let title: String
        public let description: String
        public let status: String
    }

    public struct ProjectInfo: Sendable {
        public let name: String
        public let directory: String   // host directory
        public let mount: String       // guest mount path (e.g. "/project")
    }

    public struct TeamInfo: Sendable {
        public let name: String
        public let mount: String       // guest mount path (e.g. "/team")
    }
}
