import Foundation
import Logging
import PecanSettings
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import HuggingFace
import Tokenizers

private let serverLogger = Logger(label: "com.pecan.mlx-manager")

public actor MLXServerManager {
    public static let shared = MLXServerManager()
    
    private var currentModelContainer: ModelContainer? = nil
    private var currentModelID: String? = nil
    
    private init() {}
    
    public func getContainer(provider: ProviderConfig) async throws -> ModelContainer {
        guard let repo = provider.huggingfaceRepo, !repo.isEmpty else {
            throw NSError(domain: "MLXServerManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Provider '\(provider.id)' does not specify a HuggingFace Repo."])
        }
        
        if let container = currentModelContainer, currentModelID == repo {
            return container
        }
        
        // Unload old container if any
        currentModelContainer = nil
        currentModelID = repo
        
        serverLogger.info("Loading local MLX model '\(repo)' natively in-process using SwiftMLX...")
        
        // Use LLMModelFactory with MLXHuggingFace downloader and tokenizer loaders
        let container = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: repo)
        ) { progress in
            let pct = Int(progress.fractionCompleted * 100)
            serverLogger.info("Loading model progress: \(pct)%")
        }
        
        currentModelContainer = container
        serverLogger.info("Model '\(repo)' successfully loaded into SwiftMLX memory.")
        return container
    }
    
    public func generateInProcess(
        container: ModelContainer,
        messages: [[String: String]],
        parameters: GenerateParameters,
        onChunk: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        // 1. Format prompt using chat template
        let formattedPrompt = try await container.perform { context in
            let tokens = try context.tokenizer.applyChatTemplate(messages: messages)
            return context.tokenizer.decode(tokenIds: tokens)
        }
        
        // 2. Perform generation
        let fullOutput = try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(prompt: formattedPrompt))
            
            var generatedText = ""
            var currentLength = 0
            
            _ = try MLXLMCommon.generate(
                input: input,
                parameters: parameters,
                context: context
            ) { tokens in
                // Decode full sequence generated so far
                let text = context.tokenizer.decode(tokenIds: tokens)
                // Extract only the new chunk
                if text.count > currentLength {
                    let chunk = String(text.dropFirst(currentLength))
                    currentLength = text.count
                    generatedText += chunk
                    onChunk(chunk)
                }
                return .more
            }
            return generatedText
        }
        return fullOutput
    }
    
    public func shutdownAll() {
        // Free memory by releasing the loaded model container
        currentModelContainer = nil
        currentModelID = nil
        serverLogger.info("Unloaded all SwiftMLX models.")
    }
}
