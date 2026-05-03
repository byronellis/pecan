import Foundation
import PecanShared
import Logging

private let subagentLogger = Logger(label: "com.pecan.subagent")

/// A self-contained agent run with its own in-memory context.
///
/// The subagent sends LLM completion requests via the shared gRPC sink, embedding
/// its own `messages` array in `paramsJson` so the server uses them instead of the
/// session's stored context. `CompletionRouter` matches responses back by request ID.
public actor SubagentSession {
    nonisolated let agentID: String
    let sink: any AgentEventSink
    let toolManager: ToolManager
    let toolTags: Set<String>
    private var messages: [[String: Any]] = []

    public init(
        sink: any AgentEventSink,
        toolManager: ToolManager = .shared,
        toolTags: Set<String> = ["core", "web", "skills"]
    ) {
        self.agentID = "sub-\(UUID().uuidString.prefix(8))"
        self.sink = sink
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
        let requestID = UUID().uuidString

        // Build paramsJson that overrides the server's session context with our local messages
        var params: [String: Any] = ["messages": messages]
        if let toolData = try? await toolManager.getToolDefinitions(tags: toolTags),
           let toolDefs = try? JSONSerialization.jsonObject(with: toolData) as? [[String: Any]],
           !toolDefs.isEmpty {
            params["tools"] = toolDefs
        }

        let paramsData = try JSONSerialization.data(withJSONObject: params)
        let paramsJSON = String(data: paramsData, encoding: .utf8)!

        // Register with CompletionRouter BEFORE sending (actor call guarantees ordering)
        let responseStream = await CompletionRouter.shared.makeStream(requestID: requestID)

        var event = Pecan_AgentEvent()
        var req = Pecan_LLMCompletionRequest()
        req.requestID = requestID
        req.modelKey = ""
        req.paramsJson = paramsJSON
        event.completionRequest = req
        try await sink.send(event)

        // Wait for the response
        for await response in responseStream {
            if !response.errorMessage.isEmpty {
                throw NSError(
                    domain: "SubagentSession",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "LLM error: \(response.errorMessage)"]
                )
            }
            return response.responseJson
        }
        throw NSError(domain: "SubagentSession", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Response stream ended without a value"])
    }
}
