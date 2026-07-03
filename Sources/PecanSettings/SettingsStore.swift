import Foundation
import GRDB
import Security

// MARK: - Keychain Secrets Support
public struct KeychainHelper {
    public static let service = "com.pecan.provider-keys"
    public static let account = "all_keys"

    /// In-process cache: once loaded from Keychain (which may prompt), we
    /// remember it for the rest of the process lifetime.
    private nonisolated(unsafe) static var cache: [String: String]? = nil
    private static let lock = NSLock()

    public static func setCache(_ dict: [String: String]) {
        lock.lock()
        cache = dict
        lock.unlock()
    }

    public static func getCache() -> [String: String]? {
        lock.lock()
        let c = cache
        lock.unlock()
        return c
    }

    private static func loadDictionary() -> [String: String] {
        lock.lock()
        if let cached = cache {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        guard status == errSecSuccess, let data = dataTypeRef as? Data,
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }

        lock.lock()
        cache = dict
        lock.unlock()
        return dict
    }

    private static func saveDictionary(_ dict: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(dict) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            lock.lock()
            cache = dict
            lock.unlock()
            return true
        }
        return false
    }

    public static func set(key: String, value: String) -> Bool {
        var dict = loadDictionary()
        dict[key] = value
        return saveDictionary(dict)
    }

    public static func setMultiple(_ keys: [String: String]) -> Bool {
        var dict = loadDictionary()
        var changed = false
        for (k, v) in keys {
            if dict[k] != v {
                dict[k] = v
                changed = true
            }
        }
        if changed {
            return saveDictionary(dict)
        }
        return true
    }

    public static func get(key: String) -> String? {
        let dict = loadDictionary()
        return dict[key]
    }

    public static func getAllKeys() -> [String: String] {
        return loadDictionary()
    }

    public static func delete(key: String) {
        var dict = loadDictionary()
        dict.removeValue(forKey: key)
        _ = saveDictionary(dict)
    }

    public static func resolveKey(providerID: String, providerType: String, dbKey: String?) -> String? {
        let env = ProcessInfo.processInfo.environment
        let idLower = providerID.lowercased()
        let typeLower = providerType.lowercased()
        
        if idLower.contains("fireworks") || typeLower == "fireworks" {
            if let envKey = env["FIREWORKS_API_KEY"], !envKey.isEmpty {
                return envKey
            }
        }
        
        if idLower.contains("huggingface") || idLower.contains("hf") || typeLower == "huggingface" {
            if let envKey = env["HF_TOKEN"] ?? env["HF_API_KEY"] ?? env["HUGGING_FACE_HUB_TOKEN"], !envKey.isEmpty {
                return envKey
            }
        }

        if idLower.contains("openai") || typeLower == "openai" {
            if let envKey = env["OPENAI_API_KEY"], !envKey.isEmpty {
                return envKey
            }
        }

        if idLower.contains("anthropic") || typeLower == "anthropic" {
            if let envKey = env["ANTHROPIC_API_KEY"], !envKey.isEmpty {
                return envKey
            }
        }
        
        if dbKey == "keychain" {
            return get(key: providerID)
        }
        return dbKey
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
        if self.db != nil { return }
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
            
            let providerCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM providers") ?? 0
            if providerCount == 0 {
                // OpenAI
                try db.execute(sql: """
                    INSERT INTO providers (id, type, url, api_key, enabled)
                    VALUES ('openai', 'openai', 'https://api.openai.com', NULL, 1)
                """)
                // Anthropic
                try db.execute(sql: """
                    INSERT INTO providers (id, type, url, api_key, enabled)
                    VALUES ('anthropic', 'anthropic', 'https://api.anthropic.com', NULL, 1)
                """)
                // Fireworks.AI
                try db.execute(sql: """
                    INSERT INTO providers (id, type, url, api_key, enabled)
                    VALUES ('fireworks', 'fireworks', 'https://api.fireworks.ai', NULL, 1)
                """)
                // Hugging Face
                try db.execute(sql: """
                    INSERT INTO providers (id, type, url, api_key, enabled)
                    VALUES ('huggingface', 'huggingface', 'https://api-inference.huggingface.co', NULL, 1)
                """)
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
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS agents (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL,
                    system_prompt TEXT NOT NULL DEFAULT '',
                    model TEXT,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    allowed_tool_tags TEXT NOT NULL DEFAULT 'core,web,skills,meta'
                )
            """)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agents") ?? 0
            if count == 0 {
                try db.execute(sql: """
                    INSERT INTO agents (id, name, description, system_prompt, model, enabled, allowed_tool_tags)
                    VALUES ('general', 'General Purpose', 'General-purpose coding agent with file, shell, and web tools.', '', NULL, 1, 'core,web,skills,meta')
                """)
                try db.execute(sql: """
                    INSERT INTO agents (id, name, description, system_prompt, model, enabled, allowed_tool_tags)
                    VALUES ('planning', 'Planning', 'Analyse scope and produce a structured plan before implementing.', '', NULL, 1, 'core,meta')
                """)
                try db.execute(sql: """
                    INSERT INTO agents (id, name, description, system_prompt, model, enabled, allowed_tool_tags)
                    VALUES ('coordinator', 'Coordinator', 'Coordinate tasks by delegating them to specialized subagents.', '', NULL, 1, 'core,meta')
                """)
            }
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
                let dbKey: String? = $0["api_key"]
                return ProviderConfig(
                    id: id,
                    type: $0["type"],
                    url: $0["url"],
                    apiKey: dbKey,
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
            let dbKey: String? = row["api_key"]
            return ProviderConfig(
                id: row["id"],
                type: row["type"],
                url: row["url"],
                apiKey: dbKey,
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
            
            // Migrate routing config!
            let data = try JSONEncoder().encode(parsed.routing)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            try db.execute(
                sql: "INSERT OR REPLACE INTO global (key, value) VALUES ('routing_config', ?)",
                arguments: [json]
            )
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
        var routing: RoutingConfig = RoutingConfig()
    }

    private func parseYAMLConfig(_ yaml: String) -> YAMLConfig? {
        var result = YAMLConfig()
        var currentModel: String?
        var inModels = false
        var inTools = false
        var inRouting = false
        
        var currentRoutingSub = ""
        var currentFallbackItem: ModelRef? = nil
        var inProviderBudgets = false

        for rawLine in yaml.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.isEmpty else { continue }

            let indent = line.prefix(while: { $0 == " " }).count

            if indent == 0 {
                inModels = trimmed.hasPrefix("models:") || trimmed.hasPrefix("providers:")
                inTools = trimmed.hasPrefix("tools:")
                inRouting = trimmed.hasPrefix("routing:")
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
            } else if inRouting {
                if indent == 2 {
                    inProviderBudgets = false
                    if trimmed.hasPrefix("strategy:") {
                        let val = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                        result.routing.strategy = RoutingStrategy(rawValue: val) ?? .simple
                    } else if trimmed.hasPrefix("default_route:") {
                        currentRoutingSub = "default_route"
                    } else if trimmed.hasPrefix("auto_judge_model:") {
                        currentRoutingSub = "auto_judge_model"
                    } else if trimmed.hasPrefix("fallback_chain:") {
                        currentRoutingSub = "fallback_chain"
                        if let item = currentFallbackItem {
                            result.routing.fallbackChain.append(item)
                            currentFallbackItem = nil
                        }
                    } else if trimmed.hasPrefix("context_window_fallback:") {
                        currentRoutingSub = "context_window_fallback"
                    } else if trimmed.hasPrefix("content_policy_fallback:") {
                        currentRoutingSub = "content_policy_fallback"
                    } else if trimmed.hasPrefix("circuit_breaker:") {
                        currentRoutingSub = "circuit_breaker"
                    } else if trimmed.hasPrefix("budgets:") {
                        currentRoutingSub = "budgets"
                    }
                } else if indent >= 4 {
                    let kv = trimmed.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                    let key = kv[0]
                    let val = kv.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)

                    if currentRoutingSub == "default_route" {
                        if key == "provider" { result.routing.defaultRoute.providerID = val }
                        else if key == "model" { result.routing.defaultRoute.modelID = val }
                    } else if currentRoutingSub == "auto_judge_model" {
                        if result.routing.autoJudgeModel == nil { result.routing.autoJudgeModel = ModelRef(providerID: "", modelID: "") }
                        if key == "provider" { result.routing.autoJudgeModel?.providerID = val }
                        else if key == "model" { result.routing.autoJudgeModel?.modelID = val }
                    } else if currentRoutingSub == "context_window_fallback" {
                        if result.routing.contextWindowFallback == nil { result.routing.contextWindowFallback = ModelRef(providerID: "", modelID: "") }
                        if key == "provider" { result.routing.contextWindowFallback?.providerID = val }
                        else if key == "model" { result.routing.contextWindowFallback?.modelID = val }
                    } else if currentRoutingSub == "content_policy_fallback" {
                        if result.routing.contentPolicyFallback == nil { result.routing.contentPolicyFallback = ModelRef(providerID: "", modelID: "") }
                        if key == "provider" { result.routing.contentPolicyFallback?.providerID = val }
                        else if key == "model" { result.routing.contentPolicyFallback?.modelID = val }
                    } else if currentRoutingSub == "circuit_breaker" {
                        if key == "enabled" { result.routing.circuitBreakerEnabled = (val == "true") }
                        else if key == "fail_threshold" { result.routing.circuitBreakerFailThreshold = Int(val) ?? 3 }
                        else if key == "cooldown_seconds" { result.routing.circuitBreakerCooldownSeconds = Int(val) ?? 60 }
                    } else if currentRoutingSub == "budgets" {
                        if key == "enabled" { result.routing.budgetEnabled = (val == "true") }
                        else if key == "provider_budgets" { inProviderBudgets = true }
                        else if inProviderBudgets {
                            result.routing.providerBudgets.append(ProviderBudget(providerID: key, dailyLimitUSD: Double(val) ?? 0.0))
                        }
                    } else if currentRoutingSub == "fallback_chain" {
                        if trimmed.hasPrefix("-") {
                            if let item = currentFallbackItem {
                                result.routing.fallbackChain.append(item)
                            }
                            let clean = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                            let parts = clean.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                            if parts.count >= 2 {
                                let k = parts[0]
                                let v = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                                currentFallbackItem = ModelRef(providerID: k == "provider" ? v : "", modelID: k == "model" ? v : "")
                            } else {
                                currentFallbackItem = ModelRef(providerID: "", modelID: "")
                            }
                        } else if kv.count >= 2 {
                            if key == "provider" { currentFallbackItem?.providerID = val }
                            else if key == "model" { currentFallbackItem?.modelID = val }
                        }
                    }
                }
            }
        }
        if let item = currentFallbackItem {
            result.routing.fallbackChain.append(item)
        }
        return result
    }

    // MARK: - Routing Config

    /// Load the current routing configuration from the in-memory DB.
    /// Returns a default (simple / empty) config if none has been saved yet.
    public func loadRoutingConfig() throws -> RoutingConfig {
        guard let db else { throw SettingsError.notOpen }
        let json: String? = try db.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM global WHERE key = 'routing_config'")
        }
        guard let json, let data = json.data(using: .utf8) else {
            return RoutingConfig()
        }
        return (try? JSONDecoder().decode(RoutingConfig.self, from: data)) ?? RoutingConfig()
    }

    /// Persist the routing configuration to the in-memory DB.
    public func saveRoutingConfig(_ config: RoutingConfig) throws {
        guard let db else { throw SettingsError.notOpen }
        let data = try JSONEncoder().encode(config)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try db.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO global (key, value) VALUES ('routing_config', ?)",
                arguments: [json]
            )
        }
    }

    // MARK: - Agents

    public func allAgents() throws -> [AgentConfig] {
        guard let db else { throw SettingsError.notOpen }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM agents ORDER BY id")
            return rows.map {
                let tagsStr: String = $0["allowed_tool_tags"] ?? "core,web,skills,meta"
                let tags = tagsStr.components(separatedBy: ",").filter { !$0.isEmpty }
                return AgentConfig(
                    id: $0["id"],
                    name: $0["name"],
                    description: $0["description"],
                    systemPrompt: $0["system_prompt"] ?? "",
                    model: $0["model"],
                    enabled: ($0["enabled"] as Int) != 0,
                    allowedToolTags: tags
                )
            }
        }
    }

    public func agent(id: String) throws -> AgentConfig? {
        guard let db else { throw SettingsError.notOpen }
        return try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM agents WHERE id = ?", arguments: [id]) else {
                return nil
            }
            let tagsStr: String = row["allowed_tool_tags"] ?? "core,web,skills,meta"
            let tags = tagsStr.components(separatedBy: ",").filter { !$0.isEmpty }
            return AgentConfig(
                id: row["id"],
                name: row["name"],
                description: row["description"],
                systemPrompt: row["system_prompt"] ?? "",
                model: row["model"],
                enabled: (row["enabled"] as Int) != 0,
                allowedToolTags: tags
            )
        }
    }

    public func saveAgent(_ agent: AgentConfig) throws {
        guard let db else { throw SettingsError.notOpen }
        let tagsStr = agent.allowedToolTags.joined(separator: ",")
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO agents (id, name, description, system_prompt, model, enabled, allowed_tool_tags)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [agent.id, agent.name, agent.description, agent.systemPrompt, agent.model, agent.enabled ? 1 : 0, tagsStr]
            )
        }
    }

    public func deleteAgent(id: String) throws {
        guard let db else { throw SettingsError.notOpen }
        try db.write { db in
            try db.execute(sql: "DELETE FROM agents WHERE id = ?", arguments: [id])
        }
    }
}

public enum SettingsError: Error {
    case notOpen
}
