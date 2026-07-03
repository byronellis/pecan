import Foundation
import GRDB
import Security

// MARK: - Keychain Secrets Support
public struct KeychainHelper {
    public static let service = "com.pecan.provider-keys"

    public static func set(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
        
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    public static func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        guard status == errSecSuccess, let data = dataTypeRef as? Data else {
            return nil
        }
        
        return String(data: data, encoding: .utf8)
    }

    public static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Persistent settings store at ~/.pecan/settings.db.
/// Replaces the old ~/.pecan/config.yaml.
public actor SettingsStore {
    public static let shared = SettingsStore()

    private var db: DatabaseQueue?

    private init() {}

    // MARK: - Setup

    public func open() throws {
        // Automatically clean up old persistent settings.db if present to avoid pollution
        let oldDbPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pecan/settings.db").path
        if FileManager.default.fileExists(atPath: oldDbPath) {
            try? FileManager.default.removeItem(atPath: oldDbPath)
        }

        // Open an in-memory database so settings.db is never written to disk
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS providers (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL DEFAULT 'openai',
                    url TEXT,
                    api_key TEXT,
                    hf_repo TEXT,
                    ctx_window_override INTEGER,
                    enabled INTEGER NOT NULL DEFAULT 1
                )
            """)
            // Schema migrations: add columns introduced after initial release
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(providers)")
            let columnNames = Set(columns.compactMap { $0["name"] as? String })
            if !columnNames.contains("request_timeout") {
                try db.execute(sql: "ALTER TABLE providers ADD COLUMN request_timeout REAL")
            }
            if !columnNames.contains("use_streaming") {
                try db.execute(sql: "ALTER TABLE providers ADD COLUMN use_streaming INTEGER DEFAULT 1")
            }
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS global (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS persona_models (
                    persona TEXT PRIMARY KEY,
                    model_key TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS provider_models (
                    provider_id TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    PRIMARY KEY (provider_id, model_id)
                )
            """)
        }
        self.db = queue
        try migrateFromYAMLIfNeeded(queue: queue)
    }

    // MARK: - Providers

    public func allProviders() throws -> [ProviderConfig] {
        guard let db else { throw SettingsError.notOpen }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM providers ORDER BY id")
            return rows.map {
                let id: String = $0["id"]
                let keychainKey = KeychainHelper.get(key: id)
                let dbKey: String? = $0["api_key"]
                return ProviderConfig(
                    id: id,
                    type: $0["type"],
                    url: $0["url"],
                    apiKey: keychainKey ?? dbKey,
                    huggingfaceRepo: $0["hf_repo"],
                    contextWindowOverride: $0["ctx_window_override"],
                    requestTimeout: $0["request_timeout"],
                    useStreaming: ($0["use_streaming"] as Int? ?? 1) != 0,
                    enabled: ($0["enabled"] as Int) != 0
                )
            }
        }
    }

    public func provider(id: String) throws -> ProviderConfig? {
        guard let db else { throw SettingsError.notOpen }
        return try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM providers WHERE id = ?", arguments: [id]) else {
                return nil
            }
            let keychainKey = KeychainHelper.get(key: id)
            let dbKey: String? = row["api_key"]
            return ProviderConfig(
                id: row["id"],
                type: row["type"],
                url: row["url"],
                apiKey: keychainKey ?? dbKey,
                huggingfaceRepo: row["hf_repo"],
                contextWindowOverride: row["ctx_window_override"],
                requestTimeout: row["request_timeout"],
                useStreaming: (row["use_streaming"] as Int? ?? 1) != 0,
                enabled: (row["enabled"] as Int) != 0
            )
        }
    }

    public func upsertProvider(_ p: ProviderConfig) throws {
        guard let db else { throw SettingsError.notOpen }
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO providers (id, type, url, api_key, hf_repo, ctx_window_override, request_timeout, use_streaming, enabled)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        type = excluded.type,
                        url = excluded.url,
                        api_key = excluded.api_key,
                        hf_repo = excluded.hf_repo,
                        ctx_window_override = excluded.ctx_window_override,
                        request_timeout = excluded.request_timeout,
                        use_streaming = excluded.use_streaming,
                        enabled = excluded.enabled
                """,
                arguments: [p.id, p.type, p.url, p.apiKey, p.huggingfaceRepo,
                            p.contextWindowOverride, p.requestTimeout,
                            p.useStreaming ? 1 : 0, p.enabled ? 1 : 0]
            )
        }
    }

    public func deleteProvider(id: String) throws {
        guard let db else { throw SettingsError.notOpen }
        try db.write { db in
            try db.execute(sql: "DELETE FROM providers WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM provider_models WHERE provider_id = ?", arguments: [id])
        }
    }

    public func activeModels(providerID: String) throws -> [String] {
        guard let db else { throw SettingsError.notOpen }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT model_id FROM provider_models WHERE provider_id = ? AND enabled = 1 ORDER BY model_id", arguments: [providerID])
            return rows.map { $0["model_id"] }
        }
    }

    public func syncActiveModels(providerID: String, activeModels: [String]) throws {
        guard let db else { throw SettingsError.notOpen }
        try db.write { db in
            try db.execute(sql: "DELETE FROM provider_models WHERE provider_id = ?", arguments: [providerID])
            for model in activeModels {
                try db.execute(sql: "INSERT INTO provider_models (provider_id, model_id, enabled) VALUES (?, ?, 1)", arguments: [providerID, model])
            }
        }
    }

    // MARK: - Global settings

    public func globalDefault() throws -> String? {
        return try globalSetting(key: "default_model")
    }

    public func setGlobalDefault(_ modelKey: String) throws {
        try setGlobalSetting(key: "default_model", value: modelKey)
    }

    public func requireApproval() throws -> Bool {
        return (try globalSetting(key: "require_approval")).map { $0 == "true" } ?? false
    }

    public func setRequireApproval(_ value: Bool) throws {
        try setGlobalSetting(key: "require_approval", value: value ? "true" : "false")
    }

    // MARK: - Persona model preferences

    public func personaModel(for persona: String) throws -> String? {
        guard let db else { throw SettingsError.notOpen }
        return try db.read { db in
            try String.fetchOne(db, sql: "SELECT model_key FROM persona_models WHERE persona = ?", arguments: [persona])
        }
    }

    public func setPersonaModel(_ modelKey: String, for persona: String) throws {
        guard let db else { throw SettingsError.notOpen }
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO persona_models (persona, model_key) VALUES (?, ?)
                    ON CONFLICT(persona) DO UPDATE SET model_key = excluded.model_key
                """,
                arguments: [persona, modelKey]
            )
        }
    }

    public func clearPersonaModel(for persona: String) throws {
        guard let db else { throw SettingsError.notOpen }
        try db.write { db in
            try db.execute(sql: "DELETE FROM persona_models WHERE persona = ?", arguments: [persona])
        }
    }

    public func allPersonaModels() throws -> [(persona: String, modelKey: String)] {
        guard let db else { throw SettingsError.notOpen }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT persona, model_key FROM persona_models ORDER BY persona")
            return rows.map { (persona: $0["persona"], modelKey: $0["model_key"]) }
        }
    }

    public func resolveProviderAndModel(requestModel: String) async -> (ProviderConfig, String)? {
        var modelToResolve = requestModel
        if modelToResolve == "default" || modelToResolve.isEmpty {
            if let def = try? globalDefault(), !def.isEmpty {
                modelToResolve = def
            }
        }

        let parts = modelToResolve.components(separatedBy: "/")
        if parts.count >= 2 {
            let providerID = parts[0]
            let modelID = parts.dropFirst().joined(separator: "/")
            if let provider = try? provider(id: providerID) {
                return (provider, modelID)
            }
        }

        if let provider = try? provider(id: modelToResolve) {
            return (provider, modelToResolve)
        }

        if let def = try? globalDefault(), !def.isEmpty {
            let defParts = def.components(separatedBy: "/")
            if defParts.count >= 2 {
                let providerID = defParts[0]
                if let provider = try? provider(id: providerID) {
                    return (provider, modelToResolve)
                }
            }
        }

        if let firstProvider = try? allProviders().first(where: { $0.enabled }) {
            return (firstProvider, modelToResolve)
        }

        return nil
    }

    // MARK: - Helpers

    private func globalSetting(key: String) throws -> String? {
        guard let db else { throw SettingsError.notOpen }
        return try db.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM global WHERE key = ?", arguments: [key])
        }
    }

    private func setGlobalSetting(key: String, value: String) throws {
        guard let db else { throw SettingsError.notOpen }
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO global (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value]
            )
        }
    }

    // MARK: - YAML migration

    private func migrateFromYAMLIfNeeded(queue: DatabaseQueue) throws {
        // Use a one-time flag so deleting providers doesn't re-trigger migration
        let alreadyMigrated = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM global WHERE key = 'yaml_migration_done'")
        }
        guard alreadyMigrated == nil else { return }

        // Mark as done immediately — even if no YAML exists or parse fails
        try queue.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO global (key, value) VALUES ('yaml_migration_done', '1')")
        }

        let configPath = ProcessInfo.processInfo.environment["PECAN_CONFIG_PATH"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pecan/config.yaml").path
        guard FileManager.default.fileExists(atPath: configPath),
              let yaml = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        guard let parsed = parseYAMLConfig(yaml) else { return }

        try queue.write { db in
            for (key, model) in parsed.models {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO providers (id, type, url, api_key, hf_repo, ctx_window_override, enabled)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [key, model.type, model.url, model.apiKey,
                                model.hfRepo, model.contextWindow, model.enabled ? 1 : 0]
                )
                // Migrate active_models!
                for activeModel in model.activeModels {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO provider_models (provider_id, model_id, enabled) VALUES (?, ?, 1)",
                        arguments: [key, activeModel]
                    )
                }
            }
            if let defaultModel = parsed.defaultModel {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO global (key, value) VALUES ('default_model', ?)",
                    arguments: [defaultModel]
                )
            }
            if let requireApproval = parsed.requireApproval {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO global (key, value) VALUES ('require_approval', ?)",
                    arguments: [requireApproval ? "true" : "false"]
                )
            }
        }
    }

    // Minimal YAML parser for the migration — handles the config.yaml structure without Yams.
    private struct YAMLModel {
        var type: String = "openai"
        var url: String?
        var apiKey: String?
        var hfRepo: String?
        var contextWindow: Int?
        var enabled: Bool = true
        var activeModels: [String] = []
    }

    private struct YAMLConfig {
        var models: [String: YAMLModel] = [:]
        var defaultModel: String?
        var requireApproval: Bool?
    }

    private func parseYAMLConfig(_ yaml: String) -> YAMLConfig? {
        var result = YAMLConfig()
        var currentModel: String?
        var inModels = false
        var inTools = false

        for rawLine in yaml.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.isEmpty else { continue }

            let indent = line.prefix(while: { $0 == " " }).count

            if indent == 0 {
                inModels = trimmed.hasPrefix("models:") || trimmed.hasPrefix("providers:")
                inTools = trimmed.hasPrefix("tools:")
                currentModel = nil
                if trimmed.hasPrefix("default_model:") {
                    result.defaultModel = trimmed.components(separatedBy: ":").dropFirst()
                        .joined(separator: ":").trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            } else if inModels && indent == 2 && trimmed.hasSuffix(":") {
                currentModel = String(trimmed.dropLast())
                result.models[currentModel!] = YAMLModel()
            } else if inModels, let key = currentModel, indent >= 4 {
                if trimmed.hasPrefix("-") {
                    let mName = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !mName.isEmpty {
                        result.models[key]?.activeModels.append(mName)
                    }
                } else {
                    let kv = trimmed.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count >= 2 else { continue }
                    let val = kv.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    switch kv[0] {
                    case "provider":    result.models[key]?.type = val
                    case "url":         result.models[key]?.url = val.isEmpty ? nil : val
                    case "api_key":     result.models[key]?.apiKey = val.isEmpty ? nil : val
                    case "huggingface_repo": result.models[key]?.hfRepo = val.isEmpty ? nil : val
                    case "context_window": result.models[key]?.contextWindow = Int(val)
                    case "enabled":     result.models[key]?.enabled = (val == "true" || val == "yes" || val == "1")
                    case "active":      result.models[key]?.enabled = (val == "true" || val == "yes" || val == "1")
                    default: break
                    }
                }
            } else if inTools && indent >= 2 {
                let kv = trimmed.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                if kv[0] == "require_approval" {
                    result.requireApproval = kv.dropFirst().joined().trimmingCharacters(in: .whitespaces) == "true"
                }
            }
        }
        return result.models.isEmpty ? nil : result
    }
}

public enum SettingsError: Error {
    case notOpen
}
