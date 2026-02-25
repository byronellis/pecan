import Foundation
import Yams

public struct Config: Codable {
    public struct Models: Codable {
        public let defaultModel: String
    }
    
    public struct ModelProvider: Codable {
        public let provider: String
        public let url: String
        public let apiKey: String?
        public let modelId: String?
    }
    
    public struct Tools: Codable {
        public let requireApproval: Bool
    }
    
    public let models: [String: ModelProvider]
    public let tools: Tools
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
