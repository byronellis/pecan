import Foundation
import PecanSettings
import Logging

/// Cached model info enriched with live data from the provider's /v1/models endpoint.
struct CachedModelInfo: Sendable {
    let providerID: String
    let modelID: String        // actual ID sent to provider API
    let displayName: String
    let contextWindow: Int?

    var key: String { "\(providerID)/\(modelID)" }
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
        // MLX uses an alias, not a /v1/models endpoint
        return [CachedModelInfo(
            providerID: provider.id,
            modelID: provider.id,
            displayName: provider.id,
            contextWindow: provider.contextWindowOverride
        )]
    case "mock":
        return [CachedModelInfo(
            providerID: provider.id,
            modelID: "mock",
            displayName: "Mock Model",
            contextWindow: 8192
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
            // llama.cpp includes meta.n_ctx_train; also check meta.n_ctx for runtime ctx size
            let ctx: Int?
            if let meta = entry["meta"] as? [String: Any] {
                ctx = (meta["n_ctx"] as? Int) ?? (meta["n_ctx_train"] as? Int)
                    ?? provider.contextWindowOverride
            } else {
                ctx = provider.contextWindowOverride
            }
            return CachedModelInfo(
                providerID: provider.id,
                modelID: id,
                displayName: id,
                contextWindow: ctx
            )
        }
    } catch {
        logger.warning("Failed to fetch models from \(provider.id): \(error)")
        return []
    }
}
