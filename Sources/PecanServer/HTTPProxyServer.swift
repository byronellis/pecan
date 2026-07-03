import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import PecanSettings
import Logging
import MLXLMCommon

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
        await MLXServerManager.shared.shutdownAll()
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
            
        case (.POST, "/v1/pecan/keys"), (.POST, "/pecan/keys"):
            guard let body = body else {
                sendErrorResponse(context: context, status: .badRequest, message: "Missing request body")
                return
            }
            let data = Data(body.readableBytesView)
            handleSyncKeys(context: context, requestData: data)
            
        default:
            sendErrorResponse(context: context, status: .notFound, message: "Endpoint \(head.method) \(path) not found")
        }
    }

    private static func handleSyncKeys(context: ChannelHandlerContext, requestData: Data) {
        let box = ChannelBox(context: context)
        guard let keys = (try? JSONDecoder().decode([String: String].self, from: requestData)) else {
            sendErrorResponse(context: box.context, status: .badRequest, message: "Invalid sync keys payload")
            return
        }
        
        KeychainHelper.setCache(keys)
        
        let response: [String: Any] = ["status": "ok"]
        if let resData = try? JSONSerialization.data(withJSONObject: response) {
            sendJSONResponse(context: box.context, data: resData)
        } else {
            sendErrorResponse(context: box.context, status: .internalServerError, message: "Failed to serialize response")
        }
    }

    private static func handleGetModels(context: ChannelHandlerContext) {
        let box = ChannelBox(context: context)
        Task {
            let models = await ModelCacheStandalone.shared.allModels()
            let modelsList = models.map { m -> [String: Any] in
                return [
                    "id": m.key,
                    "object": "model",
                    "created": Int(Date().timeIntervalSince1970),
                    "owned_by": m.providerID
                ]
            }
            
            let responseObj: [String: Any] = [
                "object": "list",
                "data": modelsList
            ]
            
            guard let data = try? JSONSerialization.data(withJSONObject: responseObj) else {
                sendErrorResponse(context: box.context, status: .internalServerError, message: "Serialization failed")
                return
            }
            
            sendJSONResponse(context: box.context, data: data)
        }
    }

    private static func handleChatCompletions(context: ChannelHandlerContext, requestData: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let requestModel = json["model"] as? String else {
            sendErrorResponse(context: context, status: .badRequest, message: "Invalid JSON or missing 'model' field")
            return
        }

        let box = ChannelBox(context: context)

        Task {
            do {
                let stream = json["stream"] as? Bool ?? false
                try await routeAndExecute(
                    box: box,
                    requestModel: requestModel,
                    stream: stream,
                    json: json,
                    clientFormat: "openai"
                )
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

        let box = ChannelBox(context: context)

        Task {
            do {
                let stream = json["stream"] as? Bool ?? false
                
                // Translate Anthropic Request to OpenAI format so routeAndExecute can process it identically
                let openAIPayload = APIConverter.anthropicToOpenAI(anthropic: json, targetModel: requestModel)
                
                try await routeAndExecute(
                    box: box,
                    requestModel: requestModel,
                    stream: stream,
                    json: openAIPayload,
                    clientFormat: "anthropic"
                )
            } catch {
                sendErrorResponse(context: box.context, status: .internalServerError, message: error.localizedDescription)
            }
        }
    }

    // MARK: - Routing Execution Engine

    private static func routeAndExecute(
        box: ChannelBox,
        requestModel: String,
        stream: Bool,
        json: [String: Any],
        clientFormat: String
    ) async throws {
        // 1. Resolve candidates using routing config
        let candidates = await resolveCandidateRoutes(requestModel: requestModel, json: json)
        
        guard !candidates.isEmpty else {
            sendErrorResponse(context: box.context, status: .notFound, message: "No route or provider found for model '\(requestModel)'")
            return
        }

        var finalError: Error? = nil
        let routingConfig = (try? await SettingsStore.shared.loadRoutingConfig()) ?? RoutingConfig()

        for candidate in candidates {
            let provider = candidate.provider
            let targetModel = candidate.targetModel
            
            // 2. Check Circuit Breaker
            if routingConfig.circuitBreakerEnabled {
                let available = await CircuitBreaker.shared.isAvailable(providerID: provider.id)
                if !available {
                    serverLogger.warning("Provider \(provider.id) is cooled down / circuit-breaker active. Skipping...")
                    continue
                }
            }

            // 3. Check Budgets
            if routingConfig.budgetEnabled {
                if let limit = routingConfig.providerBudgets.first(where: { $0.providerID == provider.id }) {
                    let withinBudget = await BudgetLimiter.shared.isWithinBudget(providerID: provider.id, dailyLimitUSD: limit.dailyLimitUSD)
                    if !withinBudget {
                        sendErrorResponse(context: box.context, status: .tooManyRequests, message: "Daily budget limit exceeded for provider \(provider.id)")
                        return
                    }
                }
            }

            // 4. Attempt execution
            do {
                let (promptTok, compTok) = try await attemptRouteCompletion(
                    box: box,
                    provider: provider,
                    targetModel: targetModel,
                    stream: stream,
                    json: json,
                    requestModel: requestModel,
                    clientFormat: clientFormat
                )
                
                // 5. Record Success (Circuit Breaker)
                if routingConfig.circuitBreakerEnabled {
                    await CircuitBreaker.shared.recordSuccess(providerID: provider.id)
                }

                // 6. Record Budget spend
                if routingConfig.budgetEnabled {
                    await BudgetLimiter.shared.recordUsage(
                        providerID: provider.id,
                        providerType: provider.type,
                        promptTokens: promptTok,
                        completionTokens: compTok
                    )
                }
                
                // Success!
                return
            } catch {
                serverLogger.error("Route to provider \(provider.id) (\(targetModel)) failed: \(error.localizedDescription)")
                finalError = error
                
                // 7. Record Failure (Circuit Breaker)
                if routingConfig.circuitBreakerEnabled {
                    let threshold = routingConfig.circuitBreakerFailThreshold
                    let cooldown = routingConfig.circuitBreakerCooldownSeconds
                    await CircuitBreaker.shared.recordFailure(providerID: provider.id, threshold: threshold, cooldownSeconds: cooldown)
                }
                
                // Check if we should route to context window fallback or content policy fallback!
                if let routeErr = error as? RouteError {
                    if routeErr.isContextWindowExceeded {
                        if let fallbackRef = routingConfig.contextWindowFallback,
                           let fallbackProvider = try? await SettingsStore.shared.provider(id: fallbackRef.providerID) {
                            serverLogger.info("Context window exceeded. Falling back to context window fallback: \(fallbackRef.display)")
                            do {
                                let (pT, cT) = try await attemptRouteCompletion(
                                    box: box,
                                    provider: fallbackProvider,
                                    targetModel: fallbackRef.modelID,
                                    stream: stream,
                                    json: json,
                                    requestModel: requestModel,
                                    clientFormat: clientFormat
                                )
                                if routingConfig.budgetEnabled {
                                    await BudgetLimiter.shared.recordUsage(providerID: fallbackProvider.id, providerType: fallbackProvider.type, promptTokens: pT, completionTokens: cT)
                                }
                                return
                            } catch {
                                finalError = error
                            }
                        }
                    } else if routeErr.isContentPolicyViolation {
                        if let fallbackRef = routingConfig.contentPolicyFallback,
                           let fallbackProvider = try? await SettingsStore.shared.provider(id: fallbackRef.providerID) {
                            serverLogger.info("Content policy violation. Falling back to content policy fallback: \(fallbackRef.display)")
                            do {
                                let (pT, cT) = try await attemptRouteCompletion(
                                    box: box,
                                    provider: fallbackProvider,
                                    targetModel: fallbackRef.modelID,
                                    stream: stream,
                                    json: json,
                                    requestModel: requestModel,
                                    clientFormat: clientFormat
                                )
                                if routingConfig.budgetEnabled {
                                    await BudgetLimiter.shared.recordUsage(providerID: fallbackProvider.id, providerType: fallbackProvider.type, promptTokens: pT, completionTokens: cT)
                                }
                                return
                            } catch {
                                finalError = error
                            }
                        }
                    }
                }
            }
        }

        // If all candidates failed
        let errMsg = finalError?.localizedDescription ?? "All fallback routes failed"
        sendErrorResponse(context: box.context, status: .internalServerError, message: errMsg)
    }

    private static func resolveCandidateRoutes(requestModel: String, json: [String: Any]) async -> [(provider: ProviderConfig, targetModel: String)] {
        let routingConfig = (try? await SettingsStore.shared.loadRoutingConfig()) ?? RoutingConfig()
        
        var isExplicitRoute = false
        if requestModel.contains("/") {
            isExplicitRoute = true
        }

        var candidates: [(provider: ProviderConfig, targetModel: String)] = []

        if isExplicitRoute {
            // Explicitly requested specific provider/model
            if let (provider, targetModel) = await SettingsStore.shared.resolveProviderAndModel(requestModel: requestModel) {
                candidates.append((provider, targetModel))
            }
        } else {
            // Apply routing strategy
            switch routingConfig.strategy {
            case .simple:
                if let provider = try? await SettingsStore.shared.provider(id: routingConfig.defaultRoute.providerID) {
                    candidates.append((provider, routingConfig.defaultRoute.modelID))
                }
            case .costBased:
                // heuristic: MLX is free, Huggingface is free, Fireworks is paid.
                if let providers = try? await SettingsStore.shared.allProviders() {
                    let sorted = providers.filter { $0.enabled }.sorted { p1, p2 in
                        let c1 = p1.type.lowercased() == "mlx" || p1.type.lowercased() == "huggingface" ? 0 : 1
                        let c2 = p2.type.lowercased() == "mlx" || p2.type.lowercased() == "huggingface" ? 0 : 1
                        return c1 < c2
                    }
                    for p in sorted {
                        let active = (try? await SettingsStore.shared.activeModels(providerID: p.id)) ?? []
                        if let first = active.first {
                            candidates.append((p, first))
                        }
                    }
                }
            case .latencyBased:
                // heuristic: MLX (local) is fastest, Huggingface is next, Fireworks is next
                if let providers = try? await SettingsStore.shared.allProviders() {
                    let sorted = providers.filter { $0.enabled }.sorted { p1, p2 in
                        let c1 = p1.type.lowercased() == "mlx" ? 0 : (p1.type.lowercased() == "huggingface" ? 1 : 2)
                        let c2 = p2.type.lowercased() == "mlx" ? 0 : (p2.type.lowercased() == "huggingface" ? 1 : 2)
                        return c1 < c2
                    }
                    for p in sorted {
                        let active = (try? await SettingsStore.shared.activeModels(providerID: p.id)) ?? []
                        if let first = active.first {
                            candidates.append((p, first))
                        }
                    }
                }
            case .automatic:
                // Use a judge model!
                if let judge = routingConfig.autoJudgeModel,
                   let judgeProvider = try? await SettingsStore.shared.provider(id: judge.providerID) {
                    
                    var userPrompt = ""
                    if let messages = json["messages"] as? [[String: Any]],
                       let last = messages.last,
                       let content = last["content"] as? String {
                        userPrompt = content
                    }
                    
                    var activeModelStrings: [String] = []
                    var modelMap: [String: (ProviderConfig, String)] = [:]
                    if let providers = try? await SettingsStore.shared.allProviders() {
                        for p in providers where p.enabled {
                            let active = (try? await SettingsStore.shared.activeModels(providerID: p.id)) ?? []
                            for m in active {
                                let key = "\(p.id)/\(m)"
                                activeModelStrings.append(key)
                                modelMap[key] = (p, m)
                            }
                        }
                    }
                    
                    if !activeModelStrings.isEmpty {
                        let judgeChoice = await callJudgeModel(
                            judgeProvider: judgeProvider,
                            judgeModel: judge.modelID,
                            availableModels: activeModelStrings,
                            userPrompt: userPrompt
                        )
                        if let choice = judgeChoice, let resolved = modelMap[choice] {
                            serverLogger.info("Judge model selected route: \(choice)")
                            candidates.append(resolved)
                        }
                    }
                }
                
                // Fallback to default route if judge failed
                if candidates.isEmpty {
                    if let provider = try? await SettingsStore.shared.provider(id: routingConfig.defaultRoute.providerID) {
                        candidates.append((provider, routingConfig.defaultRoute.modelID))
                    }
                }
            }
        }

        // Always append fallback chain candidates
        for fb in routingConfig.fallbackChain {
            if let provider = try? await SettingsStore.shared.provider(id: fb.providerID) {
                if !candidates.contains(where: { $0.provider.id == provider.id && $0.targetModel == fb.modelID }) {
                    candidates.append((provider, fb.modelID))
                }
            }
        }

        // Final fallback: default route if candidates still empty
        if candidates.isEmpty {
            if let provider = try? await SettingsStore.shared.provider(id: routingConfig.defaultRoute.providerID) {
                candidates.append((provider, routingConfig.defaultRoute.modelID))
            }
        }

        return candidates
    }

    private static func callJudgeModel(
        judgeProvider: ProviderConfig,
        judgeModel: String,
        availableModels: [String],
        userPrompt: String
    ) async -> String? {
        let systemPrompt = """
        You are a routing judge for an LLM proxy server.
        Analyze the intent and complexity of the user's prompt, and choose the best model/provider.
        Available options:
        \(availableModels.joined(separator: "\n"))

        Your response must be exactly the selected model name (e.g. "provider/model") and nothing else. No markdown, no quotes, no explanations.
        """
        
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]
        
        serverLogger.info("Calling judge model \(judgeProvider.id)/\(judgeModel)...")
        
        do {
            if judgeProvider.type.lowercased() == "mlx" {
                let container = try await MLXServerManager.shared.getContainer(provider: judgeProvider)
                var genParams = GenerateParameters()
                genParams.maxTokens = 64
                genParams.temperature = 0.0
                let response = try await MLXServerManager.shared.generateInProcess(
                    container: container,
                    messages: messages,
                    parameters: genParams,
                    onChunk: { _ in }
                )
                return response.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if judgeProvider.type.lowercased() == "anthropic" {
                let payload: [String: Any] = [
                    "model": judgeModel,
                    "system": systemPrompt,
                    "messages": [["role": "user", "content": userPrompt]],
                    "max_tokens": 64,
                    "temperature": 0.0
                ]
                guard let baseURL = judgeProvider.url,
                      let url = URL(string: baseURL.hasSuffix("/") ? baseURL + "v1/messages" : baseURL + "/v1/messages") else { return nil }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                if let key = judgeProvider.apiKey, key != "none" {
                    req.setValue(key, forHTTPHeaderField: "x-api-key")
                }
                req.httpBody = try JSONSerialization.data(withJSONObject: payload)
                
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else { return nil }
                if let res = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let content = res["content"] as? [[String: Any]],
                   let text = content.first?["text"] as? String {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else {
                let payload: [String: Any] = [
                    "model": judgeModel,
                    "messages": messages,
                    "max_tokens": 64,
                    "temperature": 0.0
                ]
                guard let baseURL = judgeProvider.url,
                      let url = URL(string: baseURL.hasSuffix("/") ? baseURL + "v1/chat/completions" : baseURL + "/v1/chat/completions") else { return nil }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let key = judgeProvider.apiKey, key != "none" {
                    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                }
                req.httpBody = try JSONSerialization.data(withJSONObject: payload)
                
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else { return nil }
                if let res = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = res["choices"] as? [[String: Any]],
                   let msg = choices.first?["message"] as? [String: Any],
                   let text = msg["content"] as? String {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } catch {
            serverLogger.error("Judge routing model failed: \(error.localizedDescription)")
        }
        return nil
    }

    private static func attemptRouteCompletion(
        box: ChannelBox,
        provider: ProviderConfig,
        targetModel: String,
        stream: Bool,
        json: [String: Any],
        requestModel: String,
        clientFormat: String
    ) async throws -> (promptTokens: Int, completionTokens: Int) {
        
        if provider.type.lowercased() == "mlx" {
            let container = try await MLXServerManager.shared.getContainer(provider: provider)
            
            var messagesList: [[String: String]] = []
            if let msgArray = json["messages"] as? [[String: Any]] {
                for msg in msgArray {
                    if let role = msg["role"] as? String,
                       let content = msg["content"] as? String {
                        messagesList.append(["role": role, "content": content])
                    }
                }
            }
            
            var genParams = GenerateParameters()
            if let maxT = json["max_tokens"] as? Int { genParams.maxTokens = maxT }
            if let temp = json["temperature"] as? Double { genParams.temperature = Float(temp) }
            if let topP = json["top_p"] as? Double { genParams.topP = Float(topP) }
            
            let modelName = targetModel
            let reqId = "chatcmpl-" + UUID().uuidString.prefix(12)
            let createdTime = Int(Date().timeIntervalSince1970)
            
            let responseText: String

            if stream {
                sendStreamHeaders(context: box.context)
                
                responseText = try await MLXServerManager.shared.generateInProcess(
                    container: container,
                    messages: messagesList,
                    parameters: genParams,
                    onChunk: { chunk in
                        if clientFormat == "openai" {
                            let chunkJSON: [String: Any] = [
                                "id": reqId,
                                "object": "chat.completion.chunk",
                                "created": createdTime,
                                "model": modelName,
                                "choices": [[
                                    "index": 0,
                                    "delta": ["content": chunk],
                                    "finish_reason": NSNull()
                                ]]
                            ]
                            if let d = try? JSONSerialization.data(withJSONObject: chunkJSON),
                               let s = String(data: d, encoding: .utf8) {
                                writeStreamChunk(context: box.context, data: "data: \(s)\n\n".data(using: .utf8)!)
                            }
                        } else {
                            let chunkJSON: [String: Any] = [
                                "type": "content_block_delta",
                                "index": 0,
                                "delta": [
                                    "type": "text_delta",
                                    "text": chunk
                                ]
                            ]
                            if let d = try? JSONSerialization.data(withJSONObject: chunkJSON),
                               let s = String(data: d, encoding: .utf8) {
                                writeStreamChunk(context: box.context, data: "data: \(s)\n\n".data(using: .utf8)!)
                            }
                        }
                    }
                )
                
                if clientFormat == "openai" {
                    let stopJSON: [String: Any] = [
                        "id": reqId,
                        "object": "chat.completion.chunk",
                        "created": createdTime,
                        "model": modelName,
                        "choices": [[
                            "index": 0,
                            "delta": [:],
                            "finish_reason": "stop"
                        ]]
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: stopJSON),
                       let s = String(data: d, encoding: .utf8),
                       let ed = "data: \(s)\n\ndata: [DONE]\n\n".data(using: .utf8) {
                        writeStreamChunk(context: box.context, data: ed)
                    }
                } else {
                    let stopJSON: [String: Any] = ["type": "message_stop"]
                    if let d = try? JSONSerialization.data(withJSONObject: stopJSON),
                       let s = String(data: d, encoding: .utf8),
                       let ed = "data: \(s)\n\n".data(using: .utf8) {
                        writeStreamChunk(context: box.context, data: ed)
                    }
                }
                sendStreamEnd(context: box.context)
            } else {
                responseText = try await MLXServerManager.shared.generateInProcess(
                    container: container,
                    messages: messagesList,
                    parameters: genParams,
                    onChunk: { _ in }
                )
                
                let totalCompletionChars = responseText.count
                if clientFormat == "openai" {
                    var responseJSON: [String: Any] = [:]
                    responseJSON["id"] = reqId
                    responseJSON["object"] = "chat.completion"
                    responseJSON["created"] = createdTime
                    responseJSON["model"] = modelName
                    responseJSON["choices"] = [[
                        "index": 0,
                        "message": [
                            "role": "assistant",
                            "content": responseText
                        ],
                        "finish_reason": "stop"
                    ]]
                    let promptTokens = messagesList.reduce(0, { $0 + ($1["content"]?.count ?? 0) }) / 4
                    let completionTokens = totalCompletionChars / 4
                    responseJSON["usage"] = [
                        "prompt_tokens": promptTokens,
                        "completion_tokens": completionTokens,
                        "total_tokens": promptTokens + completionTokens
                    ]
                    let responseData = try JSONSerialization.data(withJSONObject: responseJSON)
                    sendJSONResponse(context: box.context, data: responseData)
                } else {
                    var responseJSON: [String: Any] = [:]
                    responseJSON["id"] = reqId
                    responseJSON["type"] = "message"
                    responseJSON["role"] = "assistant"
                    responseJSON["content"] = [[
                        "type": "text",
                        "text": responseText
                    ]]
                    responseJSON["model"] = modelName
                    responseJSON["stop_reason"] = "end_turn"
                    let promptTokens = messagesList.reduce(0, { $0 + ($1["content"]?.count ?? 0) }) / 4
                    let completionTokens = totalCompletionChars / 4
                    responseJSON["usage"] = [
                        "input_tokens": promptTokens,
                        "output_tokens": completionTokens
                    ]
                    let responseData = try JSONSerialization.data(withJSONObject: responseJSON)
                    sendJSONResponse(context: box.context, data: responseData)
                }
            }
            
            let promptTextLength = messagesList.reduce(0, { $0 + ($1["content"]?.count ?? 0) })
            let totalCompletionChars = responseText.count
            return (promptTokens: promptTextLength / 4, completionTokens: totalCompletionChars / 4)
        }
        
        if provider.type.lowercased() == "anthropic" {
            let anthropicPayload = APIConverter.openAIToAnthropic(openAI: json, targetModel: targetModel)
            let payloadData = try JSONSerialization.data(withJSONObject: anthropicPayload)
            
            guard let baseURL = provider.url,
                  let targetURL = URL(string: baseURL.hasSuffix("/") ? baseURL + "v1/messages" : baseURL + "/v1/messages") else {
                throw RouteError(statusCode: 400, message: "Invalid provider URL")
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
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 500
                    throw RouteError(statusCode: status, message: "Anthropic API status \(status)")
                }
                
                sendStreamHeaders(context: box.context)
                
                if clientFormat == "openai" {
                    try await handleAnthropicStreamToOpenAI(box: box, bytes: bytes, requestModel: requestModel)
                } else {
                    try await handleForwardStream(box: box, bytes: bytes)
                }
                
                let promptTextLength = (json["messages"] as? [[String: Any]])?.reduce(0, { $0 + (($1["content"] as? String)?.count ?? 0) }) ?? 0
                return (promptTokens: promptTextLength / 4, completionTokens: 100) // fallback estimation
            } else {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
                    let msg = String(data: data, encoding: .utf8) ?? "Anthropic API failure"
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 500
                    throw RouteError(statusCode: status, message: msg)
                }
                
                let anthropicResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                if clientFormat == "openai" {
                    let openAIResponse = APIConverter.anthropicToOpenAIResponse(anthropic: anthropicResponse, requestModel: requestModel)
                    let responseData = try JSONSerialization.data(withJSONObject: openAIResponse)
                    sendJSONResponse(context: box.context, data: responseData)
                } else {
                    sendJSONResponse(context: box.context, data: data)
                }
                
                var promptTok = 0
                var compTok = 0
                if let usage = anthropicResponse["usage"] as? [String: Any] {
                    promptTok = usage["input_tokens"] as? Int ?? 0
                    compTok = usage["output_tokens"] as? Int ?? 0
                }
                return (promptTokens: promptTok, completionTokens: compTok)
            }
        }
        
        // Backend is OpenAI format
        var openAIPayload = json
        openAIPayload["model"] = targetModel
        let payloadData = try JSONSerialization.data(withJSONObject: openAIPayload)
        
        guard let baseURL = provider.url,
              let targetURL = URL(string: baseURL.hasSuffix("/") ? baseURL + "v1/chat/completions" : baseURL + "/v1/chat/completions") else {
            throw RouteError(statusCode: 400, message: "Invalid provider URL")
        }
        
        var req = URLRequest(url: targetURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = provider.apiKey, key != "none" {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = payloadData
        
        if stream {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 500
                throw RouteError(statusCode: status, message: "OpenAI API status \(status)")
            }
            
            sendStreamHeaders(context: box.context)
            
            if clientFormat == "openai" {
                try await handleForwardStream(box: box, bytes: bytes)
            } else {
                try await handleOpenAIStreamToAnthropic(box: box, bytes: bytes, requestModel: requestModel)
            }
            
            let promptTextLength = (json["messages"] as? [[String: Any]])?.reduce(0, { $0 + (($1["content"] as? String)?.count ?? 0) }) ?? 0
            return (promptTokens: promptTextLength / 4, completionTokens: 100)
        } else {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "OpenAI API failure"
                let status = (response as? HTTPURLResponse)?.statusCode ?? 500
                throw RouteError(statusCode: status, message: msg)
            }
            
            let openAIResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if clientFormat == "openai" {
                sendJSONResponse(context: box.context, data: data)
            } else {
                let anthropicResponse = APIConverter.openAIToAnthropicResponse(openAI: openAIResponse, requestModel: requestModel)
                let responseData = try JSONSerialization.data(withJSONObject: anthropicResponse)
                sendJSONResponse(context: box.context, data: responseData)
            }
            
            var promptTok = 0
            var compTok = 0
            if let usage = openAIResponse["usage"] as? [String: Any] {
                promptTok = usage["prompt_tokens"] as? Int ?? 0
                compTok = usage["completion_tokens"] as? Int ?? 0
            }
            return (promptTokens: promptTok, completionTokens: compTok)
        }
    }
}

// MARK: - RouteError

struct RouteError: Error, LocalizedError {
    let statusCode: Int
    let message: String
    
    var errorDescription: String? {
        return "Route error (status code \(statusCode)): \(message)"
    }

    var isContextWindowExceeded: Bool {
        let msg = message.lowercased()
        return msg.contains("context_length") || msg.contains("context length") || msg.contains("context_window") || msg.contains("context window") || msg.contains("maximum context length") || msg.contains("token limit exceeded")
    }

    var isContentPolicyViolation: Bool {
        let msg = message.lowercased()
        return msg.contains("content_policy") || msg.contains("content policy") || msg.contains("moderation") || msg.contains("safety policy") || msg.contains("content filter") || msg.contains("harmful")
    }
}

extension HTTPProxyHandler {
    // MARK: - Streaming Relay

    private static func handleForwardStream(box: ChannelBox, bytes: URLSession.AsyncBytes) async throws {
        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            let sseLine = line + "\n"
            if let data = sseLine.data(using: .utf8) {
                writeStreamChunk(context: box.context, data: data)
            }
        }
        sendStreamEnd(context: box.context)
    }

    private static func handleAnthropicStreamToOpenAI(box: ChannelBox, bytes: URLSession.AsyncBytes, requestModel: String) async throws {
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

    private static func handleOpenAIStreamToAnthropic(box: ChannelBox, bytes: URLSession.AsyncBytes, requestModel: String) async throws {
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
        let box = ChannelBox(context: context)
        context.eventLoop.execute {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/event-stream")
            headers.add(name: "Cache-Control", value: "no-cache")
            headers.add(name: "Connection", value: "keep-alive")
            headers.add(name: "Access-Control-Allow-Origin", value: "*")
            headers.add(name: "Access-Control-Allow-Methods", value: "POST, GET, OPTIONS")
            headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Authorization")
            
            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            box.context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            box.context.flush()
        }
    }

    private static func writeStreamChunk(context: ChannelHandlerContext, data: Data) {
        let box = ChannelBox(context: context)
        context.eventLoop.execute {
            var buffer = box.context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            box.context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            box.context.flush()
        }
    }

    private static func sendStreamEnd(context: ChannelHandlerContext) {
        let box = ChannelBox(context: context)
        context.eventLoop.execute {
            box.context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    private static func sendJSONResponse(context: ChannelHandlerContext, data: Data) {
        let box = ChannelBox(context: context)
        context.eventLoop.execute {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: "\(data.count)")
            headers.add(name: "Access-Control-Allow-Origin", value: "*")
            headers.add(name: "Access-Control-Allow-Methods", value: "POST, GET, OPTIONS")
            headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Authorization")
            
            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            box.context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            
            var buffer = box.context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            box.context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            
            box.context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    private static func sendCORSResponse(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        let box = ChannelBox(context: context)
        context.eventLoop.execute {
            var headers = HTTPHeaders()
            headers.add(name: "Access-Control-Allow-Origin", value: "*")
            headers.add(name: "Access-Control-Allow-Methods", value: "POST, GET, OPTIONS")
            headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Authorization")
            headers.add(name: "Content-Length", value: "0")
            
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            box.context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            box.context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    private static func sendErrorResponse(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        let box = ChannelBox(context: context)
        context.eventLoop.execute {
            let errJSON: [String: Any] = [
                "error": [
                    "message": message,
                    "type": "proxy_error",
                    "code": status.code
                ]
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: errJSON) else {
                // Inline sendCORSResponse logic
                var headers = HTTPHeaders()
                headers.add(name: "Access-Control-Allow-Origin", value: "*")
                headers.add(name: "Access-Control-Allow-Methods", value: "POST, GET, OPTIONS")
                headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Authorization")
                headers.add(name: "Content-Length", value: "0")
                let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
                box.context.write(self.wrapOutboundOut(.head(head)), promise: nil)
                box.context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                return
            }
            
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: "\(data.count)")
            headers.add(name: "Access-Control-Allow-Origin", value: "*")
            
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            box.context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            
            var buffer = box.context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            box.context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            
            box.context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
