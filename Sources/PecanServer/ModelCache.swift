import Foundation
import PecanSettings

public actor ModelCacheStandalone {
    public static let shared = ModelCacheStandalone()
    private var models: [RemoteModelInfo] = []
    
    private init() {}

    public func refresh(providers: [ProviderConfig]) async {
        var result: [RemoteModelInfo] = []
        for p in providers where p.enabled {
            result.append(contentsOf: await fetchModels(from: p))
        }
        if !result.isEmpty { models = result }
    }

    public func merge(_ newModels: [RemoteModelInfo]) {
        guard let providerID = newModels.first?.providerID else { return }
        models.removeAll { $0.providerID == providerID }
        models.append(contentsOf: newModels)
    }

    public func allModels() -> [RemoteModelInfo] { models }
}

public func fetchModels(from provider: ProviderConfig) async -> [RemoteModelInfo] {
    switch provider.type.lowercased() {
    case "openai", "fireworks":
        return await fetchOpenAIModels(provider: provider)
    case "mlx":
        return [RemoteModelInfo(providerID: provider.id, modelID: provider.id,
                                contextWindow: provider.contextWindowOverride, isLoaded: true)]
    case "anthropic":
        return [
            RemoteModelInfo(providerID: provider.id, modelID: "claude-3-5-sonnet", contextWindow: 200000, isLoaded: true),
            RemoteModelInfo(providerID: provider.id, modelID: "claude-3-5-haiku", contextWindow: 200000, isLoaded: true),
            RemoteModelInfo(providerID: provider.id, modelID: "claude-3-opus", contextWindow: 200000, isLoaded: true)
        ]
    case "mock":
        return [RemoteModelInfo(providerID: provider.id, modelID: "mock",
                                contextWindow: 8192, contextWindowTrain: 8192, isLoaded: true)]
    default:
        return []
    }
}

internal func buildTargetURL(baseURL: String, endpoint: String) -> URL? {
    let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if endpoint.hasPrefix("v1/") {
        if base.hasSuffix("v1") {
            let endpointWithoutV1 = String(endpoint.dropFirst(3))
            return URL(string: base + "/" + endpointWithoutV1)
        }
    }
    return URL(string: base + "/" + endpoint)
}

private func fetchOpenAIModels(provider: ProviderConfig) async -> [RemoteModelInfo] {
    guard let baseURL = provider.url, !baseURL.isEmpty else {
        return [RemoteModelInfo(providerID: provider.id, modelID: provider.id)]
    }
    guard let url = buildTargetURL(baseURL: baseURL, endpoint: "v1/models") else { return [] }
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = "GET"
    let key = KeychainHelper.resolveKey(providerID: provider.id, providerType: provider.type, dbKey: provider.apiKey)
    if let key = key, !key.isEmpty, key.lowercased() != "none" {
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    do {
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else { return [] }
        return dataArray.compactMap { entry -> RemoteModelInfo? in
            guard let id = entry["id"] as? String else { return nil }
            let meta = entry["meta"] as? [String: Any]
            let nCtx = meta?["n_ctx"] as? Int
            let nCtxTrain = meta?["n_ctx_train"] as? Int
            let ctx = nCtx ?? nCtxTrain ?? provider.contextWindowOverride

            let isLoaded: Bool?
            if let loaded = entry["loaded"] as? Bool { isLoaded = loaded }
            else if let status = entry["status"] as? String { isLoaded = status == "loaded" }
            else if nCtx != nil { isLoaded = true }
            else { isLoaded = nil }

            let paramCount: Int?
            if let p = meta?["n_params"] as? Int { paramCount = p }
            else if let p = meta?["n_params"] as? Double { paramCount = Int(p) }
            else { paramCount = nil }

            let sizeBytes: Int?
            if let s = meta?["size"] as? Int { sizeBytes = s }
            else if let s = meta?["size"] as? Double { sizeBytes = Int(s) }
            else { sizeBytes = nil }

            return RemoteModelInfo(providerID: provider.id, modelID: id,
                                   contextWindow: ctx, contextWindowTrain: nCtxTrain,
                                   isLoaded: isLoaded, paramCount: paramCount, sizeBytes: sizeBytes)
        }
    } catch { return [] }
}
