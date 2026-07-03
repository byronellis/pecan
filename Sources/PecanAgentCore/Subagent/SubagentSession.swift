import Foundation
import Logging
import PecanSettings

private let subagentLogger = Logger(label: "com.pecan.subagent")

/// A self-contained agent run with its own in-memory context.
///
/// The subagent sends LLM completion requests directly to the local HTTP LLM Proxy server.
public actor SubagentSession {
    nonisolated let agentID: String
    let toolManager: ToolManager
    let toolTags: Set<String>
    private var messages: [[String: Any]] = []

    public init(
        toolManager: ToolManager = .shared,
        toolTags: Set<String> = ["core", "web", "skills"]
    ) {
        self.agentID = "sub-\(UUID().uuidString.prefix(8))"
        self.toolManager = toolManager
        self.toolTags = toolTags
    }

    /// Run the subagent to completion and return its final response.
    /// - Parameters:
    ///   - task: The user-visible task description.
    ///   - systemPrompt: Pre-rendered system prompt for this subagent.
    public func run(task: String, systemPrompt: String) async throws -> String {
        messages = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": task],
        ]

        let maxIterations = 50
        for iteration in 0..<maxIterations {
            subagentLogger.info("[\(agentID)] Iteration \(iteration + 1)")
            let responseJSON = try await requestCompletion()

            guard let data = responseJSON.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                return "Error: could not parse LLM response"
            }

            // Save assistant message (with tool_calls if present)
            var assistantMsg: [String: Any] = [
                "role": "assistant",
                "content": message["content"] as? String ?? "",
            ]
            if let toolCalls = message["tool_calls"] {
                assistantMsg["tool_calls"] = toolCalls
            }
            messages.append(assistantMsg)

            // Execute tool calls if present
            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                for toolCall in toolCalls {
                    guard let function = toolCall["function"] as? [String: Any],
                          let name = function["name"] as? String,
                          let arguments = function["arguments"] as? String,
                          let callId = toolCall["id"] as? String else { continue }

                    subagentLogger.info("[\(agentID)] Tool: \(name)")
                    await HookManager.shared.fire(event: "tool.before", data: [
                        "name": name,
                        "arguments": arguments,
                        "subagent_id": agentID,
                    ])
                    var result: String
                    do {
                        result = try await toolManager.executeTool(name: name, argumentsJSON: arguments)
                    } catch {
                        result = "Error: \(error.localizedDescription)"
                    }
                    await HookManager.shared.fire(event: "tool.after", data: [
                        "name": name,
                        "arguments": arguments,
                        "result": result,
                        "subagent_id": agentID,
                    ])

                    messages.append([
                        "role": "tool",
                        "tool_call_id": callId,
                        "content": result,
                    ])
                }
            } else {
                // No tool calls — this is the final response
                return message["content"] as? String ?? "(no response)"
            }
        }

        return "Error: subagent exceeded \(maxIterations) iterations without completing"
    }

    // MARK: - LLM request

    private func requestCompletion() async throws -> String {
        var params: [String: Any] = ["messages": messages]
        if let toolData = try? await toolManager.getToolDefinitions(tags: toolTags),
           let toolDefs = try? JSONSerialization.jsonObject(with: toolData) as? [[String: Any]],
           !toolDefs.isEmpty {
            params["tools"] = toolDefs
        }

        let config = ProxyConfig.load()
        let defaultModel = config.defaultModel ?? "claude-3-5-sonnet"
        params["model"] = defaultModel

        let port = (try? ServerStatus.read().port) ?? 3000
        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: params)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown completion error"
            throw NSError(domain: "SubagentSession", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}
