import Foundation
import PecanShared

public protocol LLMProvider {
    func complete(payloadJSON: String) async throws -> String
}

public class OpenAIProvider: LLMProvider {
    let config: Config.ModelProvider

    public init(config: Config.ModelProvider) {
        self.config = config
    }

    public func complete(payloadJSON: String) async throws -> String {
        guard var payload = try JSONSerialization.jsonObject(with: Data(payloadJSON.utf8), options: []) as? [String: Any] else {
            throw NSError(domain: "OpenAIProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid payload JSON"])
        }

        // Inject the model ID if present in config
        if let modelId = config.modelId, !modelId.isEmpty {
            payload["model"] = modelId
        } else if payload["model"] == nil {
            payload["model"] = "default"
        }

        guard let baseURL = config.url, !baseURL.isEmpty else {
            throw NSError(domain: "OpenAIProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "No URL configured for model"])
        }
        let urlString = baseURL.hasSuffix("/") ? baseURL + "v1/chat/completions" : baseURL + "/v1/chat/completions"

        let body = try JSONSerialization.data(withJSONObject: payload, options: [])

        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        if let apiKey = config.apiKey, !apiKey.isEmpty, apiKey.lowercased() != "none" {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAIProvider", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OpenAIProvider", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Error \(httpResponse.statusCode): \(errorString)"])
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
                    "message": [
                        "role": "assistant",
                        "content": "This is a mock response from the server."
                    ],
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
        // Parse the OpenAI-format payload to extract messages
        guard let payload = try JSONSerialization.jsonObject(with: Data(payloadJSON.utf8), options: []) as? [String: Any] else {
            throw NSError(domain: "MLXProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid payload JSON"])
        }

        var request = Pecan_MLXRequest()
        var genReq = Pecan_MLXGenerateRequest()
        genReq.requestID = UUID().uuidString
        genReq.alias = alias

        // Extract messages from OpenAI format
        if let messages = payload["messages"] as? [[String: Any]] {
            genReq.messages = messages.compactMap { msg in
                guard let role = msg["role"] as? String, let content = msg["content"] as? String else { return nil }
                var chatMsg = Pecan_MLXChatMessage()
                chatMsg.role = role
                chatMsg.content = content
                return chatMsg
            }
        }

        if let temp = payload["temperature"] as? Double {
            genReq.temperature = Float(temp)
        }
        if let maxTokens = payload["max_tokens"] as? Int {
            genReq.maxTokens = Int32(maxTokens)
        }

        request.generate = genReq

        let response = try mlxManager.sendRequest(request, timeout: 120)

        // Check for error
        if case .error(let err) = response.payload {
            throw NSError(domain: "MLXProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: err.errorMessage])
        }

        // Convert to OpenAI-compatible response format
        let genResponse = response.generate
        let openAIResponse: [String: Any] = [
            "id": "mlx-\(genReq.requestID)",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": alias,
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": genResponse.text
                    ],
                    "finish_reason": "stop"
                ]
            ],
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
    /// Set by the server at startup if MLX models are configured.
    nonisolated(unsafe) public static var mlxManager: MLXProcessManager?

    public static func create(config: Config.ModelProvider, alias: String = "") -> LLMProvider {
        switch config.resolvedProvider.lowercased() {
        case "openai":
            return OpenAIProvider(config: config)
        case "mock":
            return MockProvider()
        case "mlx":
            guard let mgr = mlxManager else {
                logger.error("MLX provider requested but MLX server is not running")
                return MockProvider()
            }
            let modelAlias = alias.isEmpty ? (config.huggingfaceRepo ?? "default") : alias
            return MLXLLMProvider(mlxManager: mgr, alias: modelAlias)
        default:
            // Fallback to OpenAI protocol for unknown providers
            return OpenAIProvider(config: config)
        }
    }
}
