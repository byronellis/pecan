import Foundation

/// A configured LLM provider (replaces Config.ModelProvider from the old YAML config).
public struct ProviderConfig: Codable, Sendable {
    public let id: String
    public let type: String          // "openai", "mlx", "mock"
    public let url: String?
    public let apiKey: String?
    public let huggingfaceRepo: String?
    public let contextWindowOverride: Int?
    public let enabled: Bool

    public init(
        id: String,
        type: String,
        url: String? = nil,
        apiKey: String? = nil,
        huggingfaceRepo: String? = nil,
        contextWindowOverride: Int? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.type = type
        self.url = url
        self.apiKey = apiKey
        self.huggingfaceRepo = huggingfaceRepo
        self.contextWindowOverride = contextWindowOverride
        self.enabled = enabled
    }
}

/// A discovered model from a provider's /v1/models endpoint.
public struct RemoteModelInfo: Sendable {
    public let providerID: String
    public let modelID: String       // ID as known to the provider
    public let contextWindow: Int?

    /// Canonical model key: "providerID/modelID", or just "modelID" for single-provider setups.
    public var key: String { "\(providerID)/\(modelID)" }

    public init(providerID: String, modelID: String, contextWindow: Int? = nil) {
        self.providerID = providerID
        self.modelID = modelID
        self.contextWindow = contextWindow
    }
}
