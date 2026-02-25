import Foundation
import Yams

public struct Config: Codable, Sendable {
    public struct Models: Codable, Sendable {
        public let defaultModel: String
    }
    
    public struct ModelProvider: Codable, Sendable {
        public let name: String?
        public let provider: String?
        public let url: String
        public let apiKey: String?
        public let modelId: String?
        public let description: String?
        
        enum CodingKeys: String, CodingKey {
            case name, provider, url, description
            case apiKey = "api_key"
            case modelId = "model_id"
        }
        
        public var resolvedProvider: String {
            return provider ?? "openai"
        }
    }
    
    public struct Tools: Codable, Sendable {
        public let requireApproval: Bool?
    }
    
    public let models: [String: ModelProvider]
    public let tools: Tools?
    public let defaultModel: String? // Optional at root depending on structure
    
    enum CodingKeys: String, CodingKey {
        case models, tools
        case defaultModel = "default_model"
    }

    public static func load() throws -> Config {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let configPath = homeDir.appendingPathComponent(".pecan/config.yaml").path
        
        guard fileManager.fileExists(atPath: configPath) else {
            throw NSError(domain: "ConfigError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Config file not found at \(configPath)"])
        }
        
        let yamlString = try String(contentsOfFile: configPath, encoding: .utf8)
        let decoder = YAMLDecoder()
        return try decoder.decode(Config.self, from: yamlString)
    }
}
