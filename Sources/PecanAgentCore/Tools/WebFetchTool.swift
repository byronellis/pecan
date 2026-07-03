import Foundation

public struct WebFetchTool: PecanTool, Sendable {
    public let name = "web_fetch"
    public let description = "Fetch a web page via HTTP GET. Returns the status code and response body."
    public let tags: Set<String> = ["web"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "url": { "type": "string", "description": "The URL to fetch." },
            "headers": {
                "type": "array",
                "description": "Optional HTTP headers.",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": { "type": "string" },
                        "value": { "type": "string" }
                    },
                    "required": ["name", "value"]
                }
            },
            "query_params": {
                "type": "array",
                "description": "Optional query parameters appended to the URL.",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": { "type": "string" },
                        "value": { "type": "string" }
                    },
                    "required": ["name", "value"]
                }
            }
        },
        "required": ["url"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let url = args["url"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: url")
        }

        let headers = parseHeaderArray(args["headers"])
        let queryParams = parseHeaderArray(args["query_params"])

        var urlComponents = URLComponents(string: url)
        if !queryParams.isEmpty {
            var items = urlComponents?.queryItems ?? []
            for q in queryParams {
                items.append(URLQueryItem(name: q.name, value: q.value))
            }
            urlComponents?.queryItems = items
        }
        guard let finalURL = urlComponents?.url else {
            throw ToolError.executionFailed("Invalid URL: \(url)")
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        for h in headers {
            request.setValue(h.value, forHTTPHeaderField: h.name)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        var body = String(data: data, encoding: .utf8) ?? ""

        // Truncate to 50KB
        if body.utf8.count > 50_000 {
            body = String(body.prefix(50_000)) + "\n... (truncated)"
        }

        return "HTTP \(statusCode)\n\(body)"
    }

    public func formatResult(_ result: String) -> String? {
        let lines = result.components(separatedBy: "\n")
        if lines.count <= 21 { return nil }
        let truncated = lines.prefix(21).joined(separator: "\n")
        return truncated + "\n... (\(lines.count) lines total, truncated)"
    }
}
