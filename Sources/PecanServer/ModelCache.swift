import Foundation
import PecanSettings
import Logging

/// Cached model info enriched with live data from the provider's /v1/models endpoint.
struct CachedModelInfo: Sendable {
    let providerID: String
    let modelID: String        // actual ID sent to provider API
    let displayName: String
    let contextWindow: Int?    // effective runtime ctx (meta.n_ctx)
    let contextWindowTrain: Int?  // training ctx (meta.n_ctx_train)
    let isLoaded: Bool?        // nil = unknown; true = confirmed loaded in server memory
    let paramCount: Int?       // total parameter count (meta.n_params)
    let sizeBytes: Int?        // model file size in bytes (meta.size)

    var key: String { "\(providerID)/\(modelID)" }

    var formattedParams: String? {
        guard let n = paramCount else { return nil }
        let b = Double(n) / 1e9
        if b >= 1.0 { return String(format: "%.1fB", b) }
        return String(format: "%.0fM", Double(n) / 1e6)
    }

    var formattedSize: String? {
        guard let s = sizeBytes else { return nil }
        let gb = Double(s) / 1_000_000_000
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(s) / 1_000_000)
    }
}

/// Fetches and caches model lists from all configured providers.
actor ModelCache {
    static let shared = ModelCache()

    private var cache: [CachedModelInfo] = []
    private var lastFetch: Date = .distantPast
    private let ttl: TimeInterval = 300 // 5 minutes

    private init() {}

    /// Returns all known models, refreshing from providers if the cache is stale.
    func models(providers: [ProviderConfig], force: Bool = false) async -> [CachedModelInfo] {
        if !force && Date().timeIntervalSince(lastFetch) < ttl && !cache.isEmpty {
            return cache
        }
        await refresh(providers: providers)
        return cache
    }

    func refresh(providers: [ProviderConfig]) async {
        var result: [CachedModelInfo] = []
        for provider in providers where provider.enabled {
            let fetched = await fetchModels(from: provider)
            result.append(contentsOf: fetched)
        }
        if !result.isEmpty {
            cache = result
            lastFetch = Date()
        }
    }

    func invalidate() {
        cache = []
        lastFetch = .distantPast
    }
}

// MARK: - Provider-specific fetching

private func fetchModels(from provider: ProviderConfig) async -> [CachedModelInfo] {
    switch provider.type.lowercased() {
    case "openai":
        return await fetchOpenAIModels(provider: provider)
    case "mlx":
        return [CachedModelInfo(
            providerID: provider.id, modelID: provider.id, displayName: provider.id,
            contextWindow: provider.contextWindowOverride, contextWindowTrain: nil,
            isLoaded: true, paramCount: nil, sizeBytes: nil
        )]
    case "mock":
        return [CachedModelInfo(
            providerID: provider.id, modelID: "mock", displayName: "Mock Model",
            contextWindow: 8192, contextWindowTrain: 8192,
            isLoaded: true, paramCount: nil, sizeBytes: nil
        )]
    default:
        return []
    }
}

private func fetchOpenAIModels(provider: ProviderConfig) async -> [CachedModelInfo] {
    guard let baseURL = provider.url, !baseURL.isEmpty else { return [] }
    let urlStr = baseURL.hasSuffix("/") ? baseURL + "v1/models" : baseURL + "/v1/models"
    guard let url = URL(string: urlStr) else { return [] }

    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let key = provider.apiKey, !key.isEmpty, key.lowercased() != "none" {
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    do {
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            return []
        }
        return dataArray.compactMap { entry -> CachedModelInfo? in
            guard let id = entry["id"] as? String else { return nil }
            let meta = entry["meta"] as? [String: Any]
            let nCtx = meta?["n_ctx"] as? Int
            let nCtxTrain = meta?["n_ctx_train"] as? Int
            let ctx = nCtx ?? nCtxTrain ?? provider.contextWindowOverride

            let isLoaded: Bool?
            if let loaded = entry["loaded"] as? Bool {
                isLoaded = loaded
            } else if let status = entry["status"] as? String {
                isLoaded = status == "loaded"
            } else if nCtx != nil {
                isLoaded = true   // runtime n_ctx present → model is in memory
            } else {
                isLoaded = nil
            }

            // llama.cpp meta.n_params is an Int; meta.size is bytes (may come as Int or Double)
            let paramCount: Int?
            if let p = meta?["n_params"] as? Int { paramCount = p }
            else if let p = meta?["n_params"] as? Double { paramCount = Int(p) }
            else { paramCount = nil }

            let sizeBytes: Int?
            if let s = meta?["size"] as? Int { sizeBytes = s }
            else if let s = meta?["size"] as? Double { sizeBytes = Int(s) }
            else { sizeBytes = nil }

            return CachedModelInfo(
                providerID: provider.id, modelID: id, displayName: id,
                contextWindow: ctx, contextWindowTrain: nCtxTrain,
                isLoaded: isLoaded, paramCount: paramCount, sizeBytes: sizeBytes
            )
        }
    } catch {
        logger.warning("Failed to fetch models from \(provider.id): \(error)")
        return []
    }
}
