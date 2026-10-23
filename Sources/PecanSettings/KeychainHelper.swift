import Foundation
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
        
        if idLower == "fireworks" {
            if let envKey = env["FIREWORKS_API_KEY"], !envKey.isEmpty {
                return envKey
            }
        }
        
        if idLower == "huggingface" {
            if let envKey = env["HF_TOKEN"] ?? env["HF_API_KEY"] ?? env["HUGGING_FACE_HUB_TOKEN"], !envKey.isEmpty {
                return envKey
            }
        }

        if idLower == "openai" {
            if let envKey = env["OPENAI_API_KEY"], !envKey.isEmpty {
                return envKey
            }
        }

        if idLower == "anthropic" {
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
