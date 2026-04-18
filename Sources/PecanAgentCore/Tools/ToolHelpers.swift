import Foundation

// MARK: - JSON Argument Parsing

func parseArguments(_ json: String) throws -> [String: Any] {
    guard let data = json.data(using: .utf8),
          let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ToolError.invalidArguments("Could not parse arguments JSON.")
    }
    return dict
}

// MARK: - ToolError

enum ToolError: LocalizedError {
    case invalidArguments(String)
    case fileNotFound(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let msg): return msg
        case .fileNotFound(let msg): return msg
        case .executionFailed(let msg): return msg
        }
    }
}

// MARK: - HTTP Header Helpers

func parseHeaderArray(_ value: Any?) -> [(name: String, value: String)] {
    guard let arr = value as? [[String: Any]] else { return [] }
    return arr.compactMap { dict in
        guard let name = dict["name"] as? String,
              let value = dict["value"] as? String else { return nil }
        return (name: name, value: value)
    }
}
