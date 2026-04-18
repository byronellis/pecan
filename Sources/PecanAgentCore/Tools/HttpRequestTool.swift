import Foundation

public struct HttpRequestTool: PecanTool, Sendable {
    public let name = "http_request"
    public let description = "Make an HTTP request (POST, PUT, PATCH, DELETE). Requires user approval before execution."
    public let tags: Set<String> = ["invoke_only"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "method": { "type": "string", "description": "HTTP method: POST, PUT, PATCH, or DELETE." },
            "url": { "type": "string", "description": "The URL to send the request to." },
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
                "description": "Optional query parameters.",
                "items": {
                    "type": "object",
                    "properties": {
                        "name": { "type": "string" },
                        "value": { "type": "string" }
                    },
                    "required": ["name", "value"]
                }
            },
            "body": { "type": "string", "description": "Request body content." }
        },
        "required": ["method", "url"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let method = args["method"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: method")
        }
        guard let url = args["url"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: url")
        }

        let allowed = ["POST", "PUT", "PATCH", "DELETE"]
        let upperMethod = method.uppercased()
        guard allowed.contains(upperMethod) else {
            throw ToolError.invalidArguments("Method must be one of: \(allowed.joined(separator: ", ")). Use web_fetch for GET requests.")
        }

        let headers = parseHeaderArray(args["headers"])
        let queryParams = parseHeaderArray(args["query_params"])
        let body = args["body"] as? String ?? ""

        let resp = try await HttpClient.shared.sendRequest(
            method: upperMethod,
            url: url,
            headers: headers,
            queryParams: queryParams,
            body: body,
            requiresApproval: true
        )

        var responseHeaders = ""
        for h in resp.responseHeaders {
            responseHeaders += "\(h.name): \(h.value)\n"
        }

        var respBody = resp.body
        if respBody.utf8.count > 50_000 {
            respBody = String(respBody.prefix(50_000)) + "\n... (truncated)"
        }

        return "HTTP \(resp.statusCode)\n\(responseHeaders)\n\(respBody)"
    }

    public func formatResult(_ result: String) -> String? {
        let lines = result.components(separatedBy: "\n")
        guard let firstLine = lines.first else { return nil }
        let bodyLength = result.utf8.count
        return "\(firstLine) — \(bodyLength) bytes"
    }
}
