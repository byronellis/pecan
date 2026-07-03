import Foundation

public struct AgentConfig: Codable, Sendable, Identifiable, Equatable {
    public var id: String // e.g. "general", "planning", "coordinator", or custom subagent name
    public var name: String
    public var description: String
    public var systemPrompt: String
    public var model: String? // "provider/model" override
    public var enabled: Bool
    public var allowedToolTags: [String]

    public var identity: String { id }

    public init(id: String, name: String, description: String, systemPrompt: String = "", model: String? = nil, enabled: Bool = true, allowedToolTags: [String] = ["core", "web", "skills", "meta"]) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.model = model
        self.enabled = enabled
        self.allowedToolTags = allowedToolTags
    }
}
