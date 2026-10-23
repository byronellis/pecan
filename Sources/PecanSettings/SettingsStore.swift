import Foundation
import Yams

public actor SettingsStore {
    public static let shared = SettingsStore()
    
    struct Settings : Codable {
        public var providers: [String:ProviderConfig] = [:]
        public var routing: RoutingConfig = RoutingConfig()
        public var agents: [String:AgentConfig] = [:]
    }
    var settings = Settings()

    private init() {
    }
    
    public func load(_ configPath: String) -> Bool {
        do {
            settings = try YAMLDecoder().decode(Settings.self,from:Data(contentsOf: URL(fileURLWithPath:configPath)))
            return true
        } catch {
            return false
        }
        
    }
    
    public func load()  -> Bool {
        let configPath = ProxyConfig.configFilePath
        if FileManager.default.fileExists(atPath: configPath) {
            return load(configPath)
        }
        return false
    }
    
    public func save() throws {
        
    }
        
    public func provider(id: String) -> ProviderConfig? {
        settings.providers[id]
    }
    
    public func allProviders() -> [ProviderConfig] {
        .init(settings.providers.values)
    }
    
    public func activeModels(providerID: String) -> [String] {
        []
    }
    
    public func resolveProviderAndModel(requestModel: String) -> (ProviderConfig,String)? {
        return nil
    }
    
    public func agent(id: String) -> AgentConfig? {
        settings.agents[id]
    }
    
    public func allAgents() -> [AgentConfig] {
        .init(settings.agents.values)
    }
    
    public func loadRoutingConfig() throws -> RoutingConfig {
        settings.routing
    }
    
}

public enum SettingsError: Error {
    case notOpen
}
