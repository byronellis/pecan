import Foundation

public struct WebSearchTool: PecanTool, Sendable {
    public let name = "web_search"
    public let description = "Search the web using DuckDuckGo. Returns a list of result titles, URLs, and snippets."
    public let tags: Set<String> = ["web"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "query": { "type": "string", "description": "The search query." },
            "num_results": { "type": "integer", "description": "Maximum number of results to return. Default 5." }
        },
        "required": ["query"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let query = args["query"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: query")
        }

        let numResults = args["num_results"] as? Int ?? 5

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw ToolError.invalidArguments("Could not encode query.")
        }

        let searchURL = "https://html.duckduckgo.com/html/?q=\(encoded)"

        let resp = try await HttpClient.shared.sendRequest(
            method: "GET",
            url: searchURL,
            requiresApproval: false
        )

        let results = parseSearchResults(html: resp.body, maxResults: numResults)

        let data = try JSONSerialization.data(withJSONObject: results)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    public func formatResult(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return nil }
        if arr.isEmpty { return "(no results)" }
        var lines: [String] = []
        for (i, item) in arr.enumerated() {
            let title = item["title"] ?? ""
            let url = item["url"] ?? ""
            let snippet = item["snippet"] ?? ""
            lines.append("\(i + 1). [\(title)](\(url))\n   \(snippet)")
        }
        return lines.joined(separator: "\n")
    }

    private func parseSearchResults(html: String, maxResults: Int) -> [[String: String]] {
        var results: [[String: String]] = []

        // Parse DuckDuckGo HTML results
        // Results are in <a class="result__a" href="...">title</a>
        // Snippets in <a class="result__snippet" ...>text</a>
        let resultPattern = #"<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#

        guard let resultRegex = try? NSRegularExpression(pattern: resultPattern, options: .dotMatchesLineSeparators),
              let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: .dotMatchesLineSeparators) else {
            return results
        }

        let range = NSRange(html.startIndex..., in: html)
        let resultMatches = resultRegex.matches(in: html, range: range)
        let snippetMatches = snippetRegex.matches(in: html, range: range)

        for (i, match) in resultMatches.prefix(maxResults).enumerated() {
            guard let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }

            var url = String(html[urlRange])
            let title = stripHTML(String(html[titleRange]))

            // DuckDuckGo wraps URLs in a redirect; extract the actual URL
            if url.contains("uddg="), let extracted = extractDDGURL(url) {
                url = extracted
            }

            var snippet = ""
            if i < snippetMatches.count {
                let sm = snippetMatches[i]
                if let snippetRange = Range(sm.range(at: 1), in: html) {
                    snippet = stripHTML(String(html[snippetRange]))
                }
            }

            results.append(["title": title, "url": url, "snippet": snippet])
        }

        return results
    }

    private func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractDDGURL(_ redirect: String) -> String? {
        guard let components = URLComponents(string: redirect),
              let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value else {
            return nil
        }
        return uddg.removingPercentEncoding ?? uddg
    }
}
