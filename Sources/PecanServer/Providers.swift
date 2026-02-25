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
            payload["model"] = "default" // Fallback
        }
        
        let urlString = config.url.hasSuffix("/") ? config.url + "v1/chat/completions" : config.url + "/v1/chat/completions"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "OpenAIProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(urlString)"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let apiKey = config.apiKey, !apiKey.isEmpty, apiKey.lowercased() != "none" {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAIProvider", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            let errorString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OpenAIProvider", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Error \(httpResponse.statusCode): \(errorString)"])
        }
        
        guard let responseString = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenAIProvider", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to decode response as UTF-8"])
        }
        
        return responseString
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

public enum ProviderFactory {
    public static func create(config: Config.ModelProvider) -> LLMProvider {
        switch config.resolvedProvider.lowercased() {
        case "openai":
            return OpenAIProvider(config: config)
        case "mock":
            return MockProvider()
        default:
            // Fallback to OpenAI protocol for unknown providers like vLLM/MLX
            return OpenAIProvider(config: config)
        }
    }
}
