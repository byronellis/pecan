import Foundation

public struct ProviderYAMLConfig: Codable, Sendable {
    public let type: String
    public let url: String?
    public let apiKey: String?

    public init(type: String, url: String? = nil, apiKey: String? = nil) {
        self.type = type
        self.url = url
        self.apiKey = apiKey
    }
}

public struct RouteYAMLConfig: Codable, Sendable {
    public let provider: String
    public let model: String?
    public let fallback: String?

    public init(provider: String, model: String? = nil, fallback: String? = nil) {
        self.provider = provider
        self.model = model
        self.fallback = fallback
    }
}

public struct ProxyConfig: Codable, Sendable {
    public var defaultModel: String?
    public var providers: [String: ProviderYAMLConfig] = [:]
    public var routing: [String: RouteYAMLConfig] = [:]

    public init() {}

    public static var configFilePath: String {
        if let envVar =  ProcessInfo.processInfo.environment["PECAN_CONFIG_PATH"] {
           return envVar
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".pecan/config.yaml").path
    }

    /// Load config from ~/.pecan/config.yaml. Creates a default config if it doesn't exist.
    public static func load() -> ProxyConfig {
        let path = configFilePath
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            let dir = (path as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let defaultYAML = """
            default_model: claude-3-5-sonnet
            providers:
              openai:
                type: openai
                url: https://api.openai.com/v1
                api_key: none
              anthropic:
                type: anthropic
                url: https://api.anthropic.com/v1
                api_key: none
            routing:
              claude-3-5-sonnet:
                provider: anthropic
              gpt-4o:
                provider: openai
            """
            try? defaultYAML.write(toFile: path, atomically: true, encoding: .utf8)
        }

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ProxyConfig()
        }

        return parse(yaml: content)
    }

    /// A simple, robust line-based YAML parser for ProxyConfig structure
    public static func parse(yaml: String) -> ProxyConfig {
        var config = ProxyConfig()
        var currentSection = "" // "providers", "routing", or ""
        var currentKey = ""
        var indentMap: [Int: String] = [:]

        let lines = yaml.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }

            let spaces = line.prefix(while: { $0 == " " || $0 == "\t" }).count

            // Resolve section transitions at 0 indent
            if spaces == 0 {
                if trimmed.hasPrefix("default_model:") {
                    config.defaultModel = extractValue(trimmed, key: "default_model:")
                } else if trimmed.hasPrefix("providers:") {
                    currentSection = "providers"
                } else if trimmed.hasPrefix("routing:") {
                    currentSection = "routing"
                } else {
                    currentSection = ""
                }
                currentKey = ""
                i += 1
                continue
            }

            // Inside a section
            if currentSection == "providers" {
                if spaces == 2 && trimmed.hasSuffix(":") {
                    currentKey = String(trimmed.dropLast())
                    config.providers[currentKey] = ProviderYAMLConfig(type: "openai")
                } else if spaces >= 4 && !currentKey.isEmpty {
                    if let (k, v) = parseKeyValue(trimmed) {
                        let current = config.providers[currentKey] ?? ProviderYAMLConfig(type: "openai")
                        var type = current.type
                        var url = current.url
                        var apiKey = current.apiKey
                        if k == "type" { type = v }
                        else if k == "url" { url = v }
                        else if k == "api_key" { apiKey = v }
                        config.providers[currentKey] = ProviderYAMLConfig(type: type, url: url, apiKey: apiKey)
                    }
                }
            } else if currentSection == "routing" {
                if spaces == 2 && trimmed.hasSuffix(":") {
                    currentKey = String(trimmed.dropLast())
                    config.routing[currentKey] = RouteYAMLConfig(provider: "")
                } else if spaces >= 4 && !currentKey.isEmpty {
                    if let (k, v) = parseKeyValue(trimmed) {
                        let current = config.routing[currentKey] ?? RouteYAMLConfig(provider: "")
                        var provider = current.provider
                        var model = current.model
                        var fallback = current.fallback
                        if k == "provider" { provider = v }
                        else if k == "model" { model = v }
                        else if k == "fallback" { fallback = v }
                        config.routing[currentKey] = RouteYAMLConfig(provider: provider, model: model, fallback: fallback)
                    }
                }
            }

            i += 1
        }

        return config
    }

    private static func extractValue(_ line: String, key: String) -> String {
        let val = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        return val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func parseKeyValue(_ line: String) -> (String, String)? {
        let parts = line.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }
        let k = parts[0].trimmingCharacters(in: .whitespaces)
        let v = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
        let cleanVal = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return (k, cleanVal)
    }
}
