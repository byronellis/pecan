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
    public let modelID: String           // ID as known to the provider
    public let contextWindow: Int?       // effective runtime ctx (meta.n_ctx)
    public let contextWindowTrain: Int?  // training ctx (meta.n_ctx_train)
    public let isLoaded: Bool?           // nil = unknown; true = confirmed loaded in server memory
    public let paramCount: Int?          // total parameter count (meta.n_params)
    public let sizeBytes: Int?           // model file size in bytes (meta.size)

    /// Canonical model key: "providerID/modelID".
    public var key: String { "\(providerID)/\(modelID)" }

    public init(
        providerID: String,
        modelID: String,
        contextWindow: Int? = nil,
        contextWindowTrain: Int? = nil,
        isLoaded: Bool? = nil,
        paramCount: Int? = nil,
        sizeBytes: Int? = nil
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.contextWindow = contextWindow
        self.contextWindowTrain = contextWindowTrain
        self.isLoaded = isLoaded
        self.paramCount = paramCount
        self.sizeBytes = sizeBytes
    }

    /// "30.5B", "7.2B", "500M" etc.
    public var formattedParams: String? {
        guard let n = paramCount else { return nil }
        let b = Double(n) / 1e9
        if b >= 1.0 { return String(format: "%.1fB", b) }
        return String(format: "%.0fM", Double(n) / 1e6)
    }

    /// "14.5 GB", "4.2 GB", "850 MB" etc.
    public var formattedSize: String? {
        guard let s = sizeBytes else { return nil }
        let gb = Double(s) / 1_000_000_000
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(s) / 1_000_000)
    }
}
