import Foundation
import Logging
import MLXLLM
import MLXLMCommon
import MLX
import PecanShared

let logger = Logger(label: "com.pecan.mlx-server")

/// Manages loaded MLX models and runs inference.
actor ModelManager {
    struct LoadedModel {
        let container: ModelContainer
        let repo: String
    }

    private var models: [String: LoadedModel] = [:]

    func load(alias: String, repo: String) async throws {
        if models[alias] != nil {
            logger.info("Model '\(alias)' already loaded, skipping")
            return
        }

        logger.info("Loading model '\(alias)' from \(repo)...")
        let modelConfiguration = ModelConfiguration(id: repo)
        let container = try await LLMModelFactory.shared.loadContainer(configuration: modelConfiguration) { progress in
            logger.info("Downloading \(alias): \(Int(progress.fractionCompleted * 100))%")
        }
        models[alias] = LoadedModel(container: container, repo: repo)
        logger.info("Model '\(alias)' loaded successfully")
    }

    func unload(alias: String) {
        if models.removeValue(forKey: alias) != nil {
            logger.info("Unloaded model '\(alias)'")
        }
    }

    func generate(alias: String, messages: [Pecan_MLXChatMessage], prompt: String, temperature: Float, maxTokens: Int) async throws -> (text: String, promptTokens: Int, completionTokens: Int) {
        guard let loaded = models[alias] else {
            throw MLXError.modelNotLoaded(alias)
        }

        // Build UserInput: use chat messages if provided, otherwise raw prompt
        let userInput: UserInput
        if !messages.isEmpty {
            let chatMessages: [Chat.Message] = messages.map { msg in
                switch msg.role {
                case "system": return .system(msg.content)
                case "assistant": return .assistant(msg.content)
                default: return .user(msg.content)
                }
            }
            userInput = UserInput(chat: chatMessages)
        } else {
            userInput = UserInput(prompt: prompt)
        }

        var generateParameters = GenerateParameters(temperature: temperature > 0 ? temperature : 0.7)
        generateParameters.maxTokens = maxTokens > 0 ? maxTokens : 2048

        // Prepare tokenized input
        let lmInput = try await loaded.container.prepare(input: userInput)

        // Generate via async stream
        let stream = try await loaded.container.generate(input: lmInput, parameters: generateParameters)

        var outputText = ""
        var promptTokenCount = 0
        var completionTokenCount = 0

        for await generation in stream {
            switch generation {
            case .chunk(let text):
                outputText += text
            case .info(let info):
                promptTokenCount = info.promptTokenCount
                completionTokenCount = info.generationTokenCount
            case .toolCall:
                break
            }
        }

        return (text: outputText, promptTokens: promptTokenCount, completionTokens: completionTokenCount)
    }

    func listLoaded() -> [(alias: String, repo: String)] {
        return models.map { ($0.key, $0.value.repo) }
    }
}

enum MLXError: Error, CustomStringConvertible {
    case modelNotLoaded(String)

    var description: String {
        switch self {
        case .modelNotLoaded(let alias): return "Model '\(alias)' is not loaded"
        }
    }
}
