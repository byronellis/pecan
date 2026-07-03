import Foundation
import PecanAgentCore
import PecanSettings

public actor LocalSession {
    public let id: String
    public var name: String
    public var projectName: String
    public var teamName: String
    public var agentNumber: Int32
    
    private var messages: [[String: Any]] = []

    public init(id: String = UUID().uuidString, name: String, projectName: String = "", teamName: String = "", agentNumber: Int32 = 0) {
        self.id = id
        self.name = name
        self.projectName = projectName
        self.teamName = teamName
        self.agentNumber = agentNumber
    }
    
    public func getMessages() -> [[String: Any]] {
        return messages
    }
    
    public func clearHistory() {
        messages.removeAll()
    }
    
    public func getAgentNumber() -> Int32 {
        self.agentNumber
    }
    
    public func getProjectName() -> String {
        self.projectName
    }
    
    public func getTeamName() -> String {
        self.teamName
    }

    public func getName() -> String {
        self.name
    }

    public func setAgentNumber(_ num: Int32) {
        self.agentNumber = num
    }
    
    public func setProjectName(_ name: String) {
        self.projectName = name
    }
    
    public func setTeamName(_ name: String) {
        self.teamName = name
    }

    /// Append a pre-existing message (e.g. system prompt)
    public func appendMessage(role: String, content: String) {
        messages.append(["role": role, "content": content])
    }

    /// Execute a user prompt. Runs the agent completion and tool-execution loop.
    public func execute(prompt: String, serverPort: Int) async throws {
        messages.append(["role": "user", "content": prompt])
        
        let maxIterations = 50
        for _ in 0..<maxIterations {
            await TerminalManager.shared.startThrobber(message: "Thinking...")
            
            // Build the system prompt using PromptComposer
            let systemPrompt = await PromptComposer.shared.compose(agentID: id, sessionID: id)
            
            // Reconstruct full payload for the LLM
            var payloadMessages: [[String: Any]] = [
                ["role": "system", "content": systemPrompt]
            ]
            payloadMessages.append(contentsOf: messages)
            
            // Retrieve available tools from ToolManager
            var params: [String: Any] = [
                "messages": payloadMessages,
                "stream": true
            ]
            if let toolData = try? await ToolManager.shared.getToolDefinitions(tags: ["core", "web", "meta"]),
               let toolDefs = try? JSONSerialization.jsonObject(with: toolData) as? [[String: Any]],
               !toolDefs.isEmpty {
                params["tools"] = toolDefs
            }
            
            let config = ProxyConfig.load()
            let defaultModel = config.defaultModel ?? "claude-3-5-sonnet"
            params["model"] = defaultModel
            
            let url = URL(string: "http://127.0.0.1:\(serverPort)/v1/chat/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: params)
            
            await TerminalManager.shared.stopThrobber()
            await TerminalManager.shared.printStreamChunk("") // clear chrome and prepare screen
            
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let errorData = try? await URLSession.shared.data(for: request).0
                let errorMsg = errorData.flatMap { String(data: $0, encoding: .utf8) } ?? "LLM connection failed"
                throw NSError(domain: "LocalSession", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }
            
            var assistantContent = ""
            
            struct ToolCallAcc {
                var id: String = ""
                var type: String = "function"
                var name: String = ""
                var arguments: String = ""
            }
            var toolCallAccs: [Int: ToolCallAcc] = [:]
            
            // Read streamed response
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let jsonStr = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if jsonStr == "[DONE]" { break }
                
                guard let chunkData = jsonStr.data(using: .utf8),
                      let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                      let choices = chunk["choices"] as? [[String: Any]],
                      let choice = choices.first else { continue }
                
                if let delta = choice["delta"] as? [String: Any] {
                    if let c = delta["content"] as? String {
                        assistantContent += c
                        await TerminalManager.shared.printStreamChunk(c)
                    }
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
            
            // Print trailing newline for the streamed assistant text
            if !assistantContent.isEmpty {
                print("\r\n\r")
                fflush(stdout)
            }
            
            // Save the assistant message to history
            var assistantMsg: [String: Any] = [
                "role": "assistant",
                "content": assistantContent
            ]
            
            var hasToolCalls = false
            if !toolCallAccs.isEmpty {
                hasToolCalls = true
                let toolCalls = toolCallAccs.sorted { $0.key < $1.key }.map { (_, acc) -> [String: Any] in
                    return [
                        "id": acc.id,
                        "type": acc.type,
                        "function": ["name": acc.name, "arguments": acc.arguments]
                    ]
                }
                assistantMsg["tool_calls"] = toolCalls
                assistantMsg["content"] = NSNull()
            }
            
            messages.append(assistantMsg)
            
            if hasToolCalls {
                // Execute tool calls
                let toolCalls = assistantMsg["tool_calls"] as! [[String: Any]]
                for tc in toolCalls {
                    guard let function = tc["function"] as? [String: Any],
                          let name = function["name"] as? String,
                          let arguments = function["arguments"] as? String,
                          let callId = tc["id"] as? String else { continue }
                    
                    await TerminalManager.shared.printSystem("Tool Call: \(name)\nArguments: \(arguments)")
                    
                    await HookManager.shared.fire(event: "tool.before", data: [
                        "name": name,
                        "arguments": arguments,
                        "session_id": id
                    ])
                    
                    var result: String
                    do {
                        result = try await ToolManager.shared.executeTool(name: name, argumentsJSON: arguments)
                    } catch {
                        result = "Error: \(error.localizedDescription)"
                    }
                    
                    await HookManager.shared.fire(event: "tool.after", data: [
                        "name": name,
                        "arguments": arguments,
                        "result": result,
                        "session_id": id
                    ])
                    
                    let displayResult = await ToolManager.shared.formatToolResult(name: name, result: result) ?? result
                    await TerminalManager.shared.printSystem("Tool Result:\n\(displayResult)")
                    
                    messages.append([
                        "role": "tool",
                        "tool_call_id": callId,
                        "content": result
                    ])
                }
            } else {
                // Done with this round of user prompt
                break
            }
        }
    }
}
