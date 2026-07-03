import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import PecanSettings
import Logging

private let serverLogger = Logger(label: "com.pecan.proxy-server")

public final class HTTPProxyServer {
    private let host: String
    private var port: Int
    private var channel: Channel?
    private let group: EventLoopGroup

    public init(host: String = "127.0.0.1", port: Int = 0) {
        self.host = host
        self.port = port
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    public func start() async throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(HTTPProxyHandler())
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        let ch = try await bootstrap.bind(host: host, port: port).get()
        self.channel = ch
        
        let boundPort = ch.localAddress?.port ?? 0
        self.port = boundPort
        serverLogger.info("HTTPProxyServer started on \(host):\(boundPort)")
        return boundPort
    }

    public func shutdown() async throws {
        try await channel?.close().get()
        try await group.shutdownGracefully()
        serverLogger.info("HTTPProxyServer shut down.")
    }
}

// MARK: - ChannelBox

/// A thread-safe wrapper to allow passing ChannelHandlerContext across Task boundaries in Swift 6 concurrency.
/// All writes and stream closures are dispatched or executed safely.
private struct ChannelBox: @unchecked Sendable {
    let context: ChannelHandlerContext
}

// MARK: - HTTPProxyHandler

private final class HTTPProxyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var state: RequestState = .idle

    private enum RequestState {
        case idle
        case readingHead(HTTPRequestHead)
        case readingBody(HTTPRequestHead, ByteBuffer)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case .head(let head):
            self.state = .readingHead(head)
        case .body(let buffer):
            switch self.state {
            case .readingHead(let head):
                self.state = .readingBody(head, buffer)
            case .readingBody(let head, var existing):
                var mutableBuffer = buffer
                existing.writeBuffer(&mutableBuffer)
                self.state = .readingBody(head, existing)
            case .idle:
                break
            }
        case .end:
            switch self.state {
            case .readingBody(let head, let body):
                self.state = .idle
                HTTPProxyHandler.handle(context: context, head: head, body: body)
            case .readingHead(let head):
                self.state = .idle
                HTTPProxyHandler.handle(context: context, head: head, body: nil)
            case .idle:
                break
            }
        }
    }

    // MARK: - Handlers

    private static func handle(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer?) {
        // Handle OPTIONS preflight
        if head.method == .OPTIONS {
            sendCORSResponse(context: context, status: .ok)
            return
        }

        let path = head.uri
        switch (head.method, path) {
        case (.GET, "/v1/models"), (.GET, "/models"):
            handleGetModels(context: context)
            
        case (.POST, "/v1/chat/completions"), (.POST, "/chat/completions"):
            guard let body = body else {
                sendErrorResponse(context: context, status: .badRequest, message: "Missing request body")
                return
            }
            let data = Data(body.readableBytesView)
            handleChatCompletions(context: context, requestData: data)
            
        case (.POST, "/v1/messages"), (.POST, "/messages"):
            guard let body = body else {
                sendErrorResponse(context: context, status: .badRequest, message: "Missing request body")
                return
            }
            let data = Data(body.readableBytesView)
            handleAnthropicMessages(context: context, requestData: data)
            
        default:
            sendErrorResponse(context: context, status: .notFound, message: "Endpoint \(head.method) \(path) not found")
        }
    }

    private static func handleGetModels(context: ChannelHandlerContext) {
        let config = ProxyConfig.load()
        let modelIDs = Array(config.routing.keys).sorted()
        
        let modelsList = modelIDs.map { modelID -> [String: Any] in
            return [
                "id": modelID,
                "object": "model",
                "created": Int(Date().timeIntervalSince1970),
                "owned_by": "pecan"
            ]
        }
        
        let responseObj: [String: Any] = [
            "object": "list",
            "data": modelsList
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: responseObj) else {
            sendErrorResponse(context: context, status: .internalServerError, message: "Serialization failed")
            return
        }
        
        sendJSONResponse(context: context, data: data)
    }

    private static func handleChatCompletions(context: ChannelHandlerContext, requestData: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let requestModel = json["model"] as? String else {
            sendErrorResponse(context: context, status: .badRequest, message: "Invalid JSON or missing 'model' field")
            return
        }

        let config = ProxyConfig.load()
        
        // Resolve model routing
        let canonicalModel = requestModel
        guard let route = config.routing[canonicalModel],
              let provider = config.providers[route.provider] else {
            sendErrorResponse(context: context, status: .notFound, message: "No route defined for model '\(canonicalModel)'")
            return
        }

        let targetModel = route.model ?? canonicalModel
        let stream = json["stream"] as? Bool ?? false
        let box = ChannelBox(context: context)

        Task {
            do {
                if provider.type.lowercased() == "anthropic" {
                    // Translate request payload: OpenAI -> Anthropic
                    let anthropicPayload = APIConverter.openAIToAnthropic(openAI: json, targetModel: targetModel)
                    let payloadData = try JSONSerialization.data(withJSONObject: anthropicPayload)
                    
                    guard let baseURL = provider.url,
                          let targetURL = URL(string: baseURL.hasSuffix("/") ? baseURL + "v1/messages" : baseURL + "/v1/messages") else {
                        throw NSError(domain: "ProxyServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid provider URL"])
                    }
                    
                    var req = URLRequest(url: targetURL)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    if let key = provider.apiKey, key != "none" {
                        req.setValue(key, forHTTPHeaderField: "x-api-key")
                    }
                    req.httpBody = payloadData
                    
                    if stream {
                        try await handleAnthropicStreamToOpenAI(box: box, request: req, requestModel: requestModel)
                    } else {
                        let (data, response) = try await URLSession.shared.data(for: req)
                        guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
                            let msg = String(data: data, encoding: .utf8) ?? "Anthropic API failure"
                            throw NSError(domain: "ProxyServer", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
                        }
                        let anthropicResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                        let openAIResponse = APIConverter.anthropicToOpenAIResponse(anthropic: anthropicResponse, requestModel: requestModel)
                        let responseData = try JSONSerialization.data(withJSONObject: openAIResponse)
                        sendJSONResponse(context: box.context, data: responseData)
                    }
                } else {
                    // Backend is OpenAI format (openai, local mlx, local llama.cpp etc.)
                    var openAIPayload = json
                    openAIPayload["model"] = targetModel
                    let payloadData = try JSONSerialization.data(withJSONObject: openAIPayload)
                    
                    guard let baseURL = provider.url,
                          let targetURL = URL(string: baseURL.hasSuffix("/") ? baseURL + "v1/chat/completions" : baseURL + "/v1/chat/completions") else {
                        throw NSError(domain: "ProxyServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid provider URL"])
                    }
                    
                    var req = URLRequest(url: targetURL)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let key = provider.apiKey, key != "none" {
                        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    }
                    req.httpBody = payloadData
                    
                    if stream {
                        try await handleForwardStream(box: box, request: req)
                    } else {
                        let (data, response) = try await URLSession.shared.data(for: req)
                        guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
                            let msg = String(data: data, encoding: .utf8) ?? "OpenAI API failure"
                            throw NSError(domain: "ProxyServer", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
                        }
                        sendJSONResponse(context: box.context, data: data)
                    }
                }
            } catch {
                sendErrorResponse(context: box.context, status: .internalServerError, message: error.localizedDescription)
            }
        }
    }

    private static func handleAnthropicMessages(context: ChannelHandlerContext, requestData: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let requestModel = json["model"] as? String else {
            sendErrorResponse(context: context, status: .badRequest, message: "Invalid JSON or missing 'model' field")
            return
        }

        let config = ProxyConfig.load()
        
        // Resolve model routing
        let canonicalModel = requestModel
        guard let route = config.routing[canonicalModel],
              let provider = config.providers[route.provider] else {
            sendErrorResponse(context: context, status: .notFound, message: "No route defined for model '\(canonicalModel)'")
            return
        }

        let targetModel = route.model ?? canonicalModel
        let stream = json["stream"] as? Bool ?? false
        let box = ChannelBox(context: context)

        Task {
            do {
                if provider.type.lowercased() == "anthropic" {
                    // Straight forward to Anthropic
                    var anthropicPayload = json
                    anthropicPayload["model"] = targetModel
                    let payloadData = try JSONSerialization.data(withJSONObject: anthropicPayload)
                    
                    guard let baseURL = provider.url,
                          let targetURL = URL(string: baseURL.hasSuffix("/") ? baseURL + "v1/messages" : baseURL + "/v1/messages") else {
                        throw NSError(domain: "ProxyServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid provider URL"])
                    }
                    
                    var req = URLRequest(url: targetURL)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    if let key = provider.apiKey, key != "none" {
                        req.setValue(key, forHTTPHeaderField: "x-api-key")
                    }
                    req.httpBody = payloadData
                    
                    if stream {
                        try await handleForwardStream(box: box, request: req)
                    } else {
                        let (data, response) = try await URLSession.shared.data(for: req)
                        guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
                            let msg = String(data: data, encoding: .utf8) ?? "Anthropic API failure"
                            throw NSError(domain: "ProxyServer", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
                        }
                        sendJSONResponse(context: box.context, data: data)
                    }
                } else {
                    // Translate request payload: Anthropic -> OpenAI
                    let openAIPayload = APIConverter.anthropicToOpenAI(anthropic: json, targetModel: targetModel)
                    let payloadData = try JSONSerialization.data(withJSONObject: openAIPayload)
                    
                    guard let baseURL = provider.url,
                          let targetURL = URL(string: baseURL.hasSuffix("/") ? baseURL + "v1/chat/completions" : baseURL + "/v1/chat/completions") else {
                        throw NSError(domain: "ProxyServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid provider URL"])
                    }
                    
                    var req = URLRequest(url: targetURL)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let key = provider.apiKey, key != "none" {
                        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    }
                    req.httpBody = payloadData
                    
                    if stream {
                        try await handleOpenAIStreamToAnthropic(box: box, request: req, requestModel: requestModel)
                    } else {
                        let (data, response) = try await URLSession.shared.data(for: req)
                        guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
                            let msg = String(data: data, encoding: .utf8) ?? "OpenAI API failure"
                            throw NSError(domain: "ProxyServer", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
                        }
                        let openAIResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                        let anthropicResponse = APIConverter.openAIToAnthropicResponse(openAI: openAIResponse, requestModel: requestModel)
                        let responseData = try JSONSerialization.data(withJSONObject: anthropicResponse)
                        sendJSONResponse(context: box.context, data: responseData)
                    }
                }
            } catch {
                sendErrorResponse(context: box.context, status: .internalServerError, message: error.localizedDescription)
            }
        }
    }

    // MARK: - Streaming Relay

    private static func handleForwardStream(box: ChannelBox, request: URLRequest) async throws {
        sendStreamHeaders(context: box.context)
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
            let errorMsg = "Stream request failed"
            writeStreamChunk(context: box.context, data: "data: {\"error\": \"\(errorMsg)\"}\n\n".data(using: .utf8)!)
            sendStreamEnd(context: box.context)
            return
        }

        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            let sseLine = line + "\n"
            if let data = sseLine.data(using: .utf8) {
                writeStreamChunk(context: box.context, data: data)
            }
        }
        
        sendStreamEnd(context: box.context)
    }

    private static func handleAnthropicStreamToOpenAI(box: ChannelBox, request: URLRequest, requestModel: String) async throws {
        sendStreamHeaders(context: box.context)
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
            let errorMsg = "Anthropic stream failed"
            writeStreamChunk(context: box.context, data: "data: {\"error\": \"\(errorMsg)\"}\n\n".data(using: .utf8)!)
            sendStreamEnd(context: box.context)
            return
        }

        let chunkID = "chatcmpl-\(UUID().uuidString.prefix(8))"
        var currentToolCallID = ""
        var currentToolName = ""
        var currentToolIndex = 0

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let eventJSON = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard let eventData = eventJSON.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            
            var choicesDelta: [String: Any] = [:]
            
            switch type {
            case "content_block_start":
                if let contentBlock = event["content_block"] as? [String: Any],
                   let blockType = contentBlock["type"] as? String {
                    if blockType == "tool_use" {
                        currentToolCallID = contentBlock["id"] as? String ?? ""
                        currentToolName = contentBlock["name"] as? String ?? ""
                        choicesDelta["tool_calls"] = [[
                            "index": currentToolIndex,
                            "id": currentToolCallID,
                            "type": "function",
                            "function": [
                                "name": currentToolName,
                                "arguments": ""
                            ]
                        ]]
                    }
                }
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   let deltaType = delta["type"] as? String {
                    if deltaType == "text_delta", let text = delta["text"] as? String {
                        choicesDelta["content"] = text
                    } else if deltaType == "input_json_delta", let partialArgs = delta["partial_json"] as? String {
                        choicesDelta["tool_calls"] = [[
                            "index": currentToolIndex,
                            "function": [
                                "arguments": partialArgs
                            ]
                        ]]
                    }
                }
            case "content_block_stop":
                if !currentToolCallID.isEmpty {
                    currentToolIndex += 1
                    currentToolCallID = ""
                    currentToolName = ""
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any] {
                    let stopReason = delta["stop_reason"] as? String ?? "stop"
                    let finishReason: String
                    switch stopReason {
                    case "end_turn": finishReason = "stop"
                    case "max_tokens": finishReason = "length"
                    case "tool_use": finishReason = "tool_calls"
                    default: finishReason = stopReason
                    }
                    choicesDelta["finish_reason"] = finishReason
                }
            default:
                break
            }
            
            if !choicesDelta.isEmpty {
                let openAIChunk: [String: Any] = [
                    "id": chunkID,
                    "object": "chat.completion.chunk",
                    "created": Int(Date().timeIntervalSince1970),
                    "model": requestModel,
                    "choices": [[
                        "index": 0,
                        "delta": choicesDelta,
                        "finish_reason": choicesDelta["finish_reason"] ?? NSNull()
                    ]]
                ]
                
                if let chunkData = try? JSONSerialization.data(withJSONObject: openAIChunk),
                   let chunkString = String(data: chunkData, encoding: .utf8) {
                    let sseLine = "data: \(chunkString)\n\n"
                    writeStreamChunk(context: box.context, data: sseLine.data(using: .utf8)!)
                }
            }
        }
        
        writeStreamChunk(context: box.context, data: "data: [DONE]\n\n".data(using: .utf8)!)
        sendStreamEnd(context: box.context)
    }

    private static func handleOpenAIStreamToAnthropic(box: ChannelBox, request: URLRequest, requestModel: String) async throws {
        sendStreamHeaders(context: box.context)
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
            let errorMsg = "OpenAI stream failed"
            writeStreamChunk(context: box.context, data: "data: {\"error\": \"\(errorMsg)\"}\n\n".data(using: .utf8)!)
            sendStreamEnd(context: box.context)
            return
        }

        let messageID = "msg_\(UUID().uuidString.prefix(8))"
        var hasStartedMessage = false
        var currentToolIndex = 0

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let chunkJSON = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if chunkJSON == "[DONE]" { break }
            
            guard let chunkData = chunkJSON.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else { continue }
            
            if !hasStartedMessage {
                hasStartedMessage = true
                let startEvent: [String: Any] = [
                    "type": "message_start",
                    "message": [
                        "id": messageID,
                        "type": "message",
                        "role": "assistant",
                        "model": requestModel,
                        "content": [],
                        "stop_reason": NSNull(),
                        "stop_sequence": NSNull()
                    ]
                ]
                writeEvent(context: box.context, event: startEvent)
            }
            
            if let choices = chunk["choices"] as? [[String: Any]], let choice = choices.first {
                if let delta = choice["delta"] as? [String: Any] {
                    if let text = delta["content"] as? String, !text.isEmpty {
                        let textEvent: [String: Any] = [
                            "type": "content_block_delta",
                            "index": 0,
                            "delta": [
                                "type": "text_delta",
                                "text": text
                            ]
                        ]
                        writeEvent(context: box.context, event: textEvent)
                    }
                    
                    if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                        for tc in toolCalls {
                            let idx = tc["index"] as? Int ?? currentToolIndex
                            if let fn = tc["function"] as? [String: Any] {
                                if let name = fn["name"] as? String, !name.isEmpty {
                                    let tcID = tc["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
                                    let toolStartEvent: [String: Any] = [
                                        "type": "content_block_start",
                                        "index": idx + 1,
                                        "content_block": [
                                            "type": "tool_use",
                                            "id": tcID,
                                            "name": name,
                                            "input": [:]
                                        ]
                                    ]
                                    writeEvent(context: box.context, event: toolStartEvent)
                                    currentToolIndex = idx
                                }
                                
                                if let argsDelta = fn["arguments"] as? String, !argsDelta.isEmpty {
                                    let toolDeltaEvent: [String: Any] = [
                                        "type": "content_block_delta",
                                        "index": idx + 1,
                                        "delta": [
                                            "type": "input_json_delta",
                                            "partial_json": argsDelta
                                        ]
                                    ]
                                    writeEvent(context: box.context, event: toolDeltaEvent)
                                }
                            }
                        }
                    }
                }
                
                if let openAIFinish = choice["finish_reason"] as? String {
                    let stopReason: String
                    switch openAIFinish {
                    case "stop": stopReason = "end_turn"
                    case "length": stopReason = "max_tokens"
                    case "tool_calls": stopReason = "tool_use"
                    default: stopReason = openAIFinish
                    }
                    
                    let messageDeltaEvent: [String: Any] = [
                        "type": "message_delta",
                        "delta": [
                            "stop_reason": stopReason,
                            "stop_sequence": NSNull()
                        ]
                    ]
                    writeEvent(context: box.context, event: messageDeltaEvent)
                }
            }
        }
        
        let stopEvent: [String: Any] = ["type": "message_stop"]
        writeEvent(context: box.context, event: stopEvent)
        sendStreamEnd(context: box.context)
    }

    private static func writeEvent(context: ChannelHandlerContext, event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        let sse = "data: \(jsonStr)\n\n"
        writeStreamChunk(context: context, data: sse.data(using: .utf8)!)
    }

    // MARK: - HTTP Writing Utilities

    private static func sendStreamHeaders(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        headers.add(name: "Access-Control-Allow-Methods", value: "POST, GET, OPTIONS")
        headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Authorization")
        
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.flush()
    }

    private static func writeStreamChunk(context: ChannelHandlerContext, data: Data) {
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.flush()
    }

    private static func sendStreamEnd(context: ChannelHandlerContext) {
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    private static func sendJSONResponse(context: ChannelHandlerContext, data: Data) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        headers.add(name: "Access-Control-Allow-Methods", value: "POST, GET, OPTIONS")
        headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Authorization")
        
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    private static func sendCORSResponse(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        var headers = HTTPHeaders()
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        headers.add(name: "Access-Control-Allow-Methods", value: "POST, GET, OPTIONS")
        headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Authorization")
        headers.add(name: "Content-Length", value: "0")
        
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    private static func sendErrorResponse(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        let errJSON: [String: Any] = [
            "error": [
                "message": message,
                "type": "proxy_error",
                "code": status.code
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: errJSON) else {
            sendCORSResponse(context: context, status: status)
            return
        }
        
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}
