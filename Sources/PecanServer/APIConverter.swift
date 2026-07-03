import Foundation
import Logging

private let converterLogger = Logger(label: "com.pecan.api-converter")

public struct APIConverter {

    // MARK: - OpenAI -> Anthropic Request Translation

    public static func openAIToAnthropic(openAI: [String: Any], targetModel: String) -> [String: Any] {
        var anthropic: [String: Any] = [:]
        anthropic["model"] = targetModel

        if let maxTokens = openAI["max_tokens"] as? Int {
            anthropic["max_tokens"] = maxTokens
        } else {
            anthropic["max_tokens"] = 4096 // Anthropic requires max_tokens
        }

        if let temp = openAI["temperature"] as? Double {
            anthropic["temperature"] = temp
        }

        if let stream = openAI["stream"] as? Bool {
            anthropic["stream"] = stream
        }

        // Extract system prompt and translate messages
        var systemPrompt = ""
        var anthropicMessages: [[String: Any]] = []

        if let messages = openAI["messages"] as? [[String: Any]] {
            for msg in messages {
                guard let role = msg["role"] as? String else { continue }
                let content = msg["content"] ?? ""

                if role == "system" {
                    if let contentStr = content as? String {
                        systemPrompt += (systemPrompt.isEmpty ? "" : "\n") + contentStr
                    }
                } else if role == "user" || role == "assistant" {
                    var translatedMsg: [String: Any] = ["role": role]
                    
                    // Handle complex content or tool calls
                    if role == "assistant", let toolCalls = msg["tool_calls"] as? [[String: Any]] {
                        var contentBlocks: [[String: Any]] = []
                        if let textContent = content as? String, !textContent.isEmpty {
                            contentBlocks.append(["type": "text", "text": textContent])
                        }
                        for tc in toolCalls {
                            guard let tcID = tc["id"] as? String,
                                  let function = tc["function"] as? [String: Any],
                                  let name = function["name"] as? String,
                                  let argsString = function["arguments"] as? String else { continue }
                            
                            let inputData = argsString.data(using: .utf8) ?? Data()
                            let inputJson = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] ?? [:]
                            
                            contentBlocks.append([
                                "type": "tool_use",
                                "id": tcID,
                                "name": name,
                                "input": inputJson
                            ])
                        }
                        translatedMsg["content"] = contentBlocks
                    } else {
                        translatedMsg["content"] = content
                    }
                    
                    anthropicMessages.append(translatedMsg)
                } else if role == "tool" {
                    // In Anthropic, tool results go into a "user" role message
                    let toolCallID = msg["tool_call_id"] as? String ?? ""
                    let contentStr = (content as? String) ?? ""
                    
                    let toolBlock: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": toolCallID,
                        "content": contentStr
                    ]
                    
                    // See if the last message in our list is a "user" message containing tool results
                    if var lastMsg = anthropicMessages.last, lastMsg["role"] as? String == "user",
                       var blocks = lastMsg["content"] as? [[String: Any]] {
                        blocks.append(toolBlock)
                        lastMsg["content"] = blocks
                        anthropicMessages[anthropicMessages.count - 1] = lastMsg
                    } else {
                        let newUserMsg: [String: Any] = [
                            "role": "user",
                            "content": [toolBlock]
                        ]
                        anthropicMessages.append(newUserMsg)
                    }
                }
            }
        }

        if !systemPrompt.isEmpty {
            anthropic["system"] = systemPrompt
        }
        anthropic["messages"] = anthropicMessages

        // Translate tools
        if let openAITools = openAI["tools"] as? [[String: Any]] {
            var anthropicTools: [[String: Any]] = []
            for tool in openAITools {
                guard let type = tool["type"] as? String, type == "function",
                      let function = tool["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let desc = function["description"] as? String else { continue }
                
                let inputSchema = function["parameters"] as? [String: Any] ?? ["type": "object", "properties": [:]]
                
                anthropicTools.append([
                    "name": name,
                    "description": desc,
                    "input_schema": inputSchema
                ])
            }
            if !anthropicTools.isEmpty {
                anthropic["tools"] = anthropicTools
            }
        }

        return anthropic
    }

    // MARK: - Anthropic -> OpenAI Response Translation

    public static func anthropicToOpenAIResponse(anthropic: [String: Any], requestModel: String) -> [String: Any] {
        var openAI: [String: Any] = [:]
        
        let id = anthropic["id"] as? String ?? "chatcmpl-\(UUID().uuidString.prefix(8))"
        openAI["id"] = id
        openAI["object"] = "chat.completion"
        openAI["created"] = Int(Date().timeIntervalSince1970)
        openAI["model"] = requestModel

        var contentString = ""
        var toolCalls: [[String: Any]] = []

        if let contentBlocks = anthropic["content"] as? [[String: Any]] {
            for block in contentBlocks {
                guard let type = block["type"] as? String else { continue }
                if type == "text", let text = block["text"] as? String {
                    contentString += text
                } else if type == "tool_use" {
                    guard let tcID = block["id"] as? String,
                          let name = block["name"] as? String,
                          let input = block["input"] as? [String: Any] else { continue }
                    
                    let argsData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
                    let argsString = String(data: argsData, encoding: .utf8) ?? "{}"
                    
                    toolCalls.append([
                        "id": tcID,
                        "type": "function",
                        "function": [
                            "name": name,
                            "arguments": argsString
                        ]
                    ])
                }
            }
        }

        var message: [String: Any] = ["role": "assistant"]
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls
            message["content"] = NSNull()
        } else {
            message["content"] = contentString
        }

        let stopReason = anthropic["stop_reason"] as? String ?? "stop"
        let finishReason: String
        switch stopReason {
        case "end_turn": finishReason = "stop"
        case "max_tokens": finishReason = "length"
        case "tool_use": finishReason = "tool_calls"
        default: finishReason = stopReason
        }

        openAI["choices"] = [[
            "index": 0,
            "message": message,
            "finish_reason": finishReason
        ]]

        if let usage = anthropic["usage"] as? [String: Any] {
            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            openAI["usage"] = [
                "prompt_tokens": input,
                "completion_tokens": output,
                "total_tokens": input + output
            ]
        }

        return openAI
    }

    // MARK: - Anthropic -> OpenAI Request Translation

    public static func anthropicToOpenAI(anthropic: [String: Any], targetModel: String) -> [String: Any] {
        var openAI: [String: Any] = [:]
        openAI["model"] = targetModel

        if let temp = anthropic["temperature"] as? Double {
            openAI["temperature"] = temp
        }
        if let maxTokens = anthropic["max_tokens"] as? Int {
            openAI["max_tokens"] = maxTokens
        }
        if let stream = anthropic["stream"] as? Bool {
            openAI["stream"] = stream
        }

        var openAIMessages: [[String: Any]] = []

        // Anthropic system prompt goes to OpenAI system message
        if let system = anthropic["system"] as? String, !system.isEmpty {
            openAIMessages.append(["role": "system", "content": system])
        }

        if let messages = anthropic["messages"] as? [[String: Any]] {
            for msg in messages {
                guard let role = msg["role"] as? String else { continue }
                
                if let contentStr = msg["content"] as? String {
                    openAIMessages.append(["role": role, "content": contentStr])
                } else if let contentBlocks = msg["content"] as? [[String: Any]] {
                    var textContent = ""
                    var toolCalls: [[String: Any]] = []
                    
                    for block in contentBlocks {
                        guard let type = block["type"] as? String else { continue }
                        if type == "text", let text = block["text"] as? String {
                            textContent += text
                        } else if type == "tool_use" {
                            guard let tcID = block["id"] as? String,
                                  let name = block["name"] as? String,
                                  let input = block["input"] as? [String: Any] else { continue }
                            
                            let argsData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
                            let argsString = String(data: argsData, encoding: .utf8) ?? "{}"
                            
                            toolCalls.append([
                                "id": tcID,
                                "type": "function",
                                "function": [
                                    "name": name,
                                    "arguments": argsString
                                ]
                            ])
                        } else if type == "tool_result" {
                            guard let useID = block["tool_use_id"] as? String,
                                  let resContent = block["content"] as? String else { continue }
                            openAIMessages.append([
                                "role": "tool",
                                "tool_call_id": useID,
                                "content": resContent
                            ])
                        }
                    }
                    
                    if role == "assistant" && !toolCalls.isEmpty {
                        var assistantMsg: [String: Any] = ["role": "assistant"]
                        if !textContent.isEmpty {
                            assistantMsg["content"] = textContent
                        } else {
                            assistantMsg["content"] = NSNull()
                        }
                        assistantMsg["tool_calls"] = toolCalls
                        openAIMessages.append(assistantMsg)
                    } else if !textContent.isEmpty {
                        openAIMessages.append(["role": role, "content": textContent])
                    }
                }
            }
        }

        openAI["messages"] = openAIMessages

        // Translate tools
        if let anthropicTools = anthropic["tools"] as? [[String: Any]] {
            var openAITools: [[String: Any]] = []
            for tool in anthropicTools {
                guard let name = tool["name"] as? String,
                      let desc = tool["description"] as? String else { continue }
                let inputSchema = tool["input_schema"] as? [String: Any] ?? ["type": "object", "properties": [:]]
                
                openAITools.append([
                    "type": "function",
                    "function": [
                        "name": name,
                        "description": desc,
                        "parameters": inputSchema
                    ]
                ])
            }
            if !openAITools.isEmpty {
                openAI["tools"] = openAITools
            }
        }

        return openAI
    }

    // MARK: - OpenAI -> Anthropic Response Translation

    public static func openAIToAnthropicResponse(openAI: [String: Any], requestModel: String) -> [String: Any] {
        var anthropic: [String: Any] = [:]
        
        let id = openAI["id"] as? String ?? "msg_\(UUID().uuidString.prefix(8))"
        anthropic["id"] = id
        anthropic["type"] = "message"
        anthropic["role"] = "assistant"
        anthropic["model"] = requestModel

        var contentBlocks: [[String: Any]] = []

        if let choices = openAI["choices"] as? [[String: Any]], let firstChoice = choices.first,
           let message = firstChoice["message"] as? [String: Any] {
            
            if let contentStr = message["content"] as? String, !contentStr.isEmpty {
                contentBlocks.append(["type": "text", "text": contentStr])
            }
            
            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    guard let tcID = tc["id"] as? String,
                          let function = tc["function"] as? [String: Any],
                          let name = function["name"] as? String,
                          let argsString = function["arguments"] as? String else { continue }
                    
                    let argsData = argsString.data(using: .utf8) ?? Data()
                    let argsJson = (try? JSONSerialization.jsonObject(with: argsData)) as? [String: Any] ?? [:]
                    
                    contentBlocks.append([
                        "type": "tool_use",
                        "id": tcID,
                        "name": name,
                        "input": argsJson
                    ])
                }
            }
            
            let openAIFinish = firstChoice["finish_reason"] as? String ?? "stop"
            let stopReason: String
            switch openAIFinish {
            case "stop": stopReason = "end_turn"
            case "length": stopReason = "max_tokens"
            case "tool_calls": stopReason = "tool_use"
            default: stopReason = openAIFinish
            }
            anthropic["stop_reason"] = stopReason
        }

        anthropic["content"] = contentBlocks

        if let usage = openAI["usage"] as? [String: Any] {
            let prompt = usage["prompt_tokens"] as? Int ?? 0
            let comp = usage["completion_tokens"] as? Int ?? 0
            anthropic["usage"] = [
                "input_tokens": prompt,
                "output_tokens": comp
            ]
        }

        return anthropic
    }
}
