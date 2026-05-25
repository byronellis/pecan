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

        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = provider.requestTimeout ?? 600

        if let apiKey = provider.apiKey, !apiKey.isEmpty, apiKey.lowercased() != "none" {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        if provider.useStreaming {
            return try await completeStreaming(request: request, payload: &payload)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
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

    private func completeStreaming(request: URLRequest, payload: inout [String: Any]) async throws -> String {
        payload["stream"] = true
        payload["stream_options"] = ["include_usage": true]

        var streamRequest = request
        // For streaming the timeout is per-chunk, not total — use a very large value so slow/buffering
        // inference servers don't time out before sending the first token.
        streamRequest.timeoutInterval = 86400
        streamRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        logger.info("OpenAIProvider: using SSE streaming for \(provider.id)")
        let (bytes, response) = try await URLSession.shared.bytes(for: streamRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAIProvider", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        if !(200...299).contains(httpResponse.statusCode) {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OpenAIProvider", code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP Error \(httpResponse.statusCode): \(errorString)"])
        }

        // If the server ignores stream:true and returns plain JSON, parse it directly.
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        if !contentType.contains("text/event-stream") {
            logger.warning("OpenAIProvider: expected SSE (text/event-stream) but got '\(contentType)' — falling back to JSON")
            var fullData = Data()
            for try await byte in bytes { fullData.append(byte) }
            return String(data: fullData, encoding: .utf8) ?? ""
        }

        // Accumulate SSE chunks into a single chat.completion response.
        var id = ""
        var model = ""
        var role = "assistant"
        var content = ""
        var finishReason: String? = nil
        var promptTokens = 0
        var completionTokens = 0
        // tool_calls[index] → accumulated fields
        struct ToolCallAcc {
            var id: String = ""
            var type: String = "function"
            var name: String = ""
            var arguments: String = ""
        }
        var toolCallAccs: [Int: ToolCallAcc] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if jsonStr == "[DONE]" { break }

            guard let chunkData = jsonStr.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else { continue }

            if id.isEmpty { id = chunk["id"] as? String ?? "" }
            if model.isEmpty { model = chunk["model"] as? String ?? "" }

            if let usage = chunk["usage"] as? [String: Any] {
                promptTokens = usage["prompt_tokens"] as? Int ?? promptTokens
                completionTokens = usage["completion_tokens"] as? Int ?? completionTokens
            }

            if let choices = chunk["choices"] as? [[String: Any]], let choice = choices.first {
                if let fr = choice["finish_reason"] as? String { finishReason = fr }
                if let delta = choice["delta"] as? [String: Any] {
                    if let r = delta["role"] as? String { role = r }
                    if let c = delta["content"] as? String { content += c }
                    if let tcs = delta["tool_calls"] as? [[String: Any]] {
                        for tc in tcs {
                            guard let idx = tc["index"] as? Int else { continue }
                            var acc = toolCallAccs[idx] ?? ToolCallAcc()
                            if let tcID = tc["id"] as? String, !tcID.isEmpty { acc.id = tcID }
                            if let tcType = tc["type"] as? String, !tcType.isEmpty { acc.type = tcType }
                            if let fn = tc["function"] as? [String: Any] {
                                if let name = fn["name"] as? String, !name.isEmpty { acc.name = name }
                                if let args = fn["arguments"] as? String { acc.arguments += args }
                            }
                            toolCallAccs[idx] = acc
                        }
                    }
                }
            }
        }

        var message: [String: Any] = ["role": role, "content": content]
        if !toolCallAccs.isEmpty {
            let toolCalls = toolCallAccs.sorted { $0.key < $1.key }.map { (_, acc) -> [String: Any] in
                return [
                    "id": acc.id,
                    "type": acc.type,
                    "function": ["name": acc.name, "arguments": acc.arguments]
                ]
            }
            message["tool_calls"] = toolCalls
            message["content"] = NSNull()  // OpenAI sets content to null when tool_calls present
        }

        let finalResponse: [String: Any] = [
            "id": id,
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": finishReason ?? "stop"
            ]],
            "usage": [
                "prompt_tokens": promptTokens,
                "completion_tokens": completionTokens,
                "total_tokens": promptTokens + completionTokens
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: finalResponse)
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
