import Foundation
import PecanShared
import PecanSettings
import Logging

public protocol LLMProvider {
    func complete(payloadJSON: String) async throws -> String
}

public class OpenAIProvider: LLMProvider {
    let provider: ProviderConfig
    let modelID: String?  // specific model to inject into the payload

    public init(provider: ProviderConfig, modelID: String? = nil) {
        self.provider = provider
        self.modelID = modelID
    }

    public func complete(payloadJSON: String) async throws -> String {
        guard var payload = try JSONSerialization.jsonObject(with: Data(payloadJSON.utf8), options: []) as? [String: Any] else {
            throw NSError(domain: "OpenAIProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid payload JSON"])
        }

        if let mid = modelID, !mid.isEmpty {
            payload["model"] = mid
        } else if payload["model"] == nil {
            payload["model"] = "default"
        }

        guard let baseURL = provider.url, !baseURL.isEmpty else {
            throw NSError(domain: "OpenAIProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "No URL configured for provider '\(provider.id)'"])
        }
        let urlString = baseURL.hasSuffix("/") ? baseURL + "v1/chat/completions" : baseURL + "/v1/chat/completions"

        let body = try JSONSerialization.data(withJSONObject: payload, options: [])

        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        if let apiKey = provider.apiKey, !apiKey.isEmpty, apiKey.lowercased() != "none" {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAIProvider", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OpenAIProvider", code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP Error \(httpResponse.statusCode): \(errorString)"])
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}

public class MockProvider: LLMProvider {
    public init() {}

    public func complete(payloadJSON: String) async throws -> String {
        let mockResponse: [String: Any] = [
            "id": "mock-id",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": "mock",
            "choices": [
                [
                    "index": 0,
                    "message": ["role": "assistant", "content": "This is a mock response from the server."],
                    "finish_reason": "stop"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: mockResponse, options: [])
        return String(data: data, encoding: .utf8)!
    }
}

public class MLXLLMProvider: LLMProvider {
    private let mlxManager: MLXProcessManager
    private let alias: String

    public init(mlxManager: MLXProcessManager, alias: String) {
        self.mlxManager = mlxManager
        self.alias = alias
    }

    public func complete(payloadJSON: String) async throws -> String {
        guard let payload = try JSONSerialization.jsonObject(with: Data(payloadJSON.utf8), options: []) as? [String: Any] else {
            throw NSError(domain: "MLXProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid payload JSON"])
        }

        var request = Pecan_MLXRequest()
        var genReq = Pecan_MLXGenerateRequest()
        genReq.requestID = UUID().uuidString
        genReq.alias = alias

        if let messages = payload["messages"] as? [[String: Any]] {
            genReq.messages = messages.compactMap { msg in
                guard let role = msg["role"] as? String, let content = msg["content"] as? String else { return nil }
                var chatMsg = Pecan_MLXChatMessage()
                chatMsg.role = role
                chatMsg.content = content
                return chatMsg
            }
        }
        if let temp = payload["temperature"] as? Double { genReq.temperature = Float(temp) }
        if let maxTokens = payload["max_tokens"] as? Int { genReq.maxTokens = Int32(maxTokens) }

        request.generate = genReq
        let response = try mlxManager.sendRequest(request, timeout: 120)

        if case .error(let err) = response.payload {
            throw NSError(domain: "MLXProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: err.errorMessage])
        }

        let genResponse = response.generate
        let openAIResponse: [String: Any] = [
            "id": "mlx-\(genReq.requestID)",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": alias,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": genResponse.text],
                "finish_reason": "stop"
            ]],
            "usage": [
                "prompt_tokens": genResponse.promptTokens,
                "completion_tokens": genResponse.completionTokens,
                "total_tokens": genResponse.promptTokens + genResponse.completionTokens
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: openAIResponse, options: [])
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public enum ProviderFactory {
    nonisolated(unsafe) public static var mlxManager: MLXProcessManager?

    /// Create a provider for a given `ProviderConfig`, optionally targeting a specific `modelID`.
    /// `modelID` is the ID as returned by /v1/models (e.g. a llama.cpp filename).
    public static func create(provider: ProviderConfig, modelID: String? = nil) -> LLMProvider {
        switch provider.type.lowercased() {
        case "openai":
            return OpenAIProvider(provider: provider, modelID: modelID)
        case "mock":
            return MockProvider()
        case "mlx":
            guard let mgr = mlxManager else {
                logger.error("MLX provider requested but MLX server is not running")
                return MockProvider()
            }
            return MLXLLMProvider(mlxManager: mgr, alias: provider.id)
        default:
            return OpenAIProvider(provider: provider, modelID: modelID)
        }
    }
}
