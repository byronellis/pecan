import Foundation
import GRDB

/// Persistent settings store at ~/.pecan/settings.db.
/// Replaces the old ~/.pecan/config.yaml.
public actor SettingsStore {
    public static let shared = SettingsStore()

    private var db: DatabaseQueue?

    private init() {}

    // MARK: - Setup

    public func open() throws {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pecan")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("settings.db").path
        let queue = try DatabaseQueue(path: path)
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
        }
        self.db = queue
        try migrateFromYAMLIfNeeded(queue: queue)
    }

    // MARK: - Providers

    public func allProviders() throws -> [ProviderConfig] {
        guard let db else { throw SettingsError.notOpen }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM providers ORDER BY id")
            return rows.map { ProviderConfig(
                id: $0["id"],
                type: $0["type"],
                url: $0["url"],
                apiKey: $0["api_key"],
                huggingfaceRepo: $0["hf_repo"],
                contextWindowOverride: $0["ctx_window_override"],
                enabled: ($0["enabled"] as Int) != 0
            )}
        }
    }

    public func provider(id: String) throws -> ProviderConfig? {
        guard let db else { throw SettingsError.notOpen }
        return try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM providers WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return ProviderConfig(
                id: row["id"],
                type: row["type"],
                url: row["url"],
                apiKey: row["api_key"],
                huggingfaceRepo: row["hf_repo"],
                contextWindowOverride: row["ctx_window_override"],
                enabled: (row["enabled"] as Int) != 0
            )
        }
    }

    public func upsertProvider(_ p: ProviderConfig) throws {
        guard let db else { throw SettingsError.notOpen }
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO providers (id, type, url, api_key, hf_repo, ctx_window_override, enabled)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        type = excluded.type,
                        url = excluded.url,
                        api_key = excluded.api_key,
                        hf_repo = excluded.hf_repo,
                        ctx_window_override = excluded.ctx_window_override,
                        enabled = excluded.enabled
                """,
                arguments: [p.id, p.type, p.url, p.apiKey, p.huggingfaceRepo,
                            p.contextWindowOverride, p.enabled ? 1 : 0]
            )
        }
    }

    public func deleteProvider(id: String) throws {
        guard let db else { throw SettingsError.notOpen }
        try db.write { db in
            try db.execute(sql: "DELETE FROM providers WHERE id = ?", arguments: [id])
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
                        VALUES (?, ?, ?, ?, ?, ?, 1)
                    """,
                    arguments: [key, model.type, model.url, model.apiKey,
                                model.hfRepo, model.contextWindow]
                )
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
                inModels = trimmed.hasPrefix("models:")
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
                default: break
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
