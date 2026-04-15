import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ANSITerminal
import GRPC
import NIO
import PecanShared


func isTableRow(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("|") && trimmed.contains("|")
}

/// Check if a line is a table separator row like |---|---|
func isTableSeparator(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("|") else { return false }
    let inner = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
    return inner.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " }
}

/// Parse a table row into cells
func parseTableCells(_ line: String) -> [String] {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    // Split by |, dropping the first/last empty elements from leading/trailing |
    var parts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map {
        String($0).trimmingCharacters(in: .whitespaces)
    }
    // Remove empty first/last from leading/trailing |
    if let first = parts.first, first.isEmpty { parts.removeFirst() }
    if let last = parts.last, last.isEmpty { parts.removeLast() }
    return parts
}

/// Render collected markdown table lines into box-drawn table
func renderTable(_ tableLines: [String]) -> [String] {
    // Separate header, separator, and body rows
    var headerCells: [String]? = nil
    var bodyRows: [[String]] = []
    var foundSeparator = false

    for line in tableLines {
        if isTableSeparator(line) {
            foundSeparator = true
            continue
        }
        let cells = parseTableCells(line)
        if !foundSeparator && headerCells == nil {
            headerCells = cells
        } else {
            bodyRows.append(cells)
        }
    }

    // If no separator was found, treat all rows as body (no header distinction)
    if !foundSeparator, let h = headerCells {
        bodyRows.insert(h, at: 0)
        headerCells = nil
    }

    let allRows: [[String]] = (headerCells.map { [$0] } ?? []) + bodyRows
    guard !allRows.isEmpty else { return [] }

    // Compute column count and widths
    let colCount = allRows.map(\.count).max() ?? 0
    guard colCount > 0 else { return [] }

    // Pad rows to uniform column count
    let paddedRows = allRows.map { row -> [String] in
        var r = row
        while r.count < colCount { r.append("") }
        return r
    }

    var colWidths = [Int](repeating: 0, count: colCount)
    for row in paddedRows {
        for (i, cell) in row.enumerated() {
            colWidths[i] = max(colWidths[i], cell.count)
        }
    }
    // Minimum width of 3 for aesthetics
    colWidths = colWidths.map { max($0, 3) }

    func horizontalLine(left: String, mid: String, right: String, fill: String) -> String {
        let segments = colWidths.map { fill + String(repeating: "─", count: $0) + fill }
        return "\(ansiDim)\(left)\(segments.joined(separator: mid))\(right)\(ansiReset)"
    }

    func dataRow(_ cells: [String], bold: Bool = false) -> String {
        let formatted = cells.enumerated().map { (i, cell) -> String in
            let padded = cell.padding(toLength: colWidths[i], withPad: " ", startingAt: 0)
            return bold ? "\(ansiBold)\(padded)\(ansiReset)" : padded
        }
        let inner = formatted.map { " \($0) " }.joined(separator: "\(ansiDim)│\(ansiReset)")
        return "\(ansiDim)│\(ansiReset)\(inner)\(ansiDim)│\(ansiReset)"
    }

    var output: [String] = []
    output.append(horizontalLine(left: "┌", mid: "┬", right: "┐", fill: "─"))

    if let header = headerCells {
        var padded = header
        while padded.count < colCount { padded.append("") }
        output.append(dataRow(padded, bold: true))
        output.append(horizontalLine(left: "├", mid: "┼", right: "┤", fill: "─"))
    }

    for row in (headerCells != nil ? bodyRows : paddedRows) {
        var padded = row
        while padded.count < colCount { padded.append("") }
        output.append(dataRow(padded))
    }

    output.append(horizontalLine(left: "└", mid: "┴", right: "┘", fill: "─"))
    return output
}

/// Apply inline markdown formatting (code, bold, italic) to a line
func applyInlineFormatting(_ line: String) -> String {
    var processed = line

    // Inline code: `code`
    let codeRegex = try! NSRegularExpression(pattern: "`([^`]+)`")
    let codeRange = NSRange(location: 0, length: processed.utf16.count)
    processed = codeRegex.stringByReplacingMatches(in: processed, options: [], range: codeRange, withTemplate: "\(ansiDim)$1\(ansiReset)")

    // Bold: **text**
    let boldRegex = try! NSRegularExpression(pattern: "\\*\\*(.*?)\\*\\*")
    let boldRange = NSRange(location: 0, length: processed.utf16.count)
    processed = boldRegex.stringByReplacingMatches(in: processed, options: [], range: boldRange, withTemplate: "\(ansiBold)$1\(ansiBoldOff)")

    // Italics: *text*
    let italicRegex = try! NSRegularExpression(pattern: "(?<!\\\\)\\*(.+?)\\*")
    let italicRange = NSRange(location: 0, length: processed.utf16.count)
    processed = italicRegex.stringByReplacingMatches(in: processed, options: [], range: italicRange, withTemplate: "\(ansiItalic)$1\(ansiItalicOff)")

    return processed
}

// Helper to format basic Markdown to ANSI
func formatMarkdown(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var result: [String] = []
    var inCodeBlock = false
    var tableBuffer: [String] = []

    for line in lines {
        // Flush table buffer if current line is not a table row
        if !tableBuffer.isEmpty && !isTableRow(line) {
            result.append(contentsOf: renderTable(tableBuffer))
            tableBuffer.removeAll()
        }

        if line.hasPrefix("```") {
            if inCodeBlock {
                result.append("\(ansiDim)└──────────────────────────────\(ansiReset)")
                inCodeBlock = false
            } else {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let header = lang.isEmpty ? "" : " \(lang)"
                result.append("\(ansiDim)┌──\(header)──────────────────────────\(ansiReset)")
                inCodeBlock = true
            }
            continue
        }

        if inCodeBlock {
            result.append("\(ansiDim)│\(ansiReset) \(line)")
            continue
        }

        // Collect table rows
        if isTableRow(line) {
            tableBuffer.append(line)
            continue
        }

        // Headers
        if line.hasPrefix("### ") {
            result.append("\(ansiBold)\(ansiDim)\(String(line.dropFirst(4)))\(ansiReset)")
            continue
        }
        if line.hasPrefix("## ") {
            result.append("\(ansiBold)\(String(line.dropFirst(3)))\(ansiReset)")
            continue
        }
        if line.hasPrefix("# ") {
            result.append("\(ansiBold)\(ansiCyan)\(String(line.dropFirst(2)))\(ansiReset)")
            continue
        }

        // Horizontal rule
        if line == "---" || line == "***" || line == "___" {
            result.append("\(ansiDim)────────────────────────────────\(ansiReset)")
            continue
        }

        // Bullet lists
        var processed = line
        if let range = processed.range(of: #"^(\s*)[*\-] "#, options: .regularExpression) {
            let indent = String(processed[processed.startIndex..<range.lowerBound])
            let rest = String(processed[range.upperBound...])
            processed = "\(indent)  • \(rest)"
        }

        result.append(applyInlineFormatting(processed))
    }

    // Flush any remaining table at end of input
    if !tableBuffer.isEmpty {
        result.append(contentsOf: renderTable(tableBuffer))
    }

    // Close unclosed code block
    if inCodeBlock {
        result.append("\(ansiDim)└──────────────────────────────\(ansiReset)")
    }

    return result.joined(separator: "\r\n")
}

/// Format a tool call arguments JSON string into readable key: value lines
func formatToolArguments(_ argsJSON: String) -> String {
    guard let data = argsJSON.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return argsJSON
    }
    return dict.map { key, value in
        let valStr: String
        if let s = value as? String {
            valStr = s
        } else if (value is [Any] || value is [String: Any]),
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let s = String(data: data, encoding: .utf8) {
            valStr = s
        } else {
            valStr = "\(value)"
        }
        return "\(ansiDim)│\(ansiReset) \(key): \(ansiDim)\(valStr)\(ansiReset)"
    }.joined(separator: "\r\n")
}

/// Truncate multi-line text to a max number of lines
func truncateResult(_ text: String, maxLines: Int = 10) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.count <= maxLines {
        return lines.map { "\(ansiDim)│\(ansiReset) \(ansiDim)\($0)\(ansiReset)" }.joined(separator: "\r\n")
    }
    let shown = lines.prefix(maxLines).map { "\(ansiDim)│\(ansiReset) \(ansiDim)\($0)\(ansiReset)" }
    return (shown + ["\(ansiDim)│ ... (\(lines.count - maxLines) more lines)\(ansiReset)"]).joined(separator: "\r\n")
}

/// Render a raw agent output text into formatted display string.
/// Returns nil for output types that only produce side effects (e.g. thinking throbber).
func renderAgentOutput(_ rawText: String) -> String? {
    guard let data = rawText.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let msgType = json["type"] else {
        // Plain text / unparseable
        return formatMarkdown(rawText)
    }

    switch msgType {
    case "thinking":
        return nil // throbber — no visual output to render

    case "tool_call":
        let toolName = json["name"] ?? "unknown"
        let args = json["arguments"] ?? "{}"
        let header = "\(ansiDim)┌─\(ansiReset) \(ansiBold)\(ansiCyan)🔧 \(toolName)\(ansiReset) \(ansiDim)──────────────────────────\(ansiReset)"
        let body = formatToolArguments(args)
        let footer = "\(ansiDim)└──────────────────────────────\(ansiReset)"
        return "\(header)\r\n\(body)\r\n\(footer)"

    case "tool_result":
        let toolName = json["name"] ?? "unknown"
        let result = json["result"] ?? ""
        let formatted = json["formatted"] ?? ""
        let displayResult = formatted.isEmpty ? result : formatted
        let header = "\(ansiDim)├─\(ansiReset) \(ansiGreen)✓ \(toolName)\(ansiReset) \(ansiDim)──────────────────────────\(ansiReset)"
        let body = truncateResult(displayResult)
        let footer = "\(ansiDim)└──────────────────────────────\(ansiReset)"
        return "\(header)\r\n\(body)\r\n\(footer)"

    case "response":
        let text = json["text"] ?? ""
        return formatMarkdown(text)

    default:
        return formatMarkdown(rawText)
    }
}

/// ANSI 256-color background for user input lines (dark gray)
/// Prompt character
let promptChar = "❯"

/// Get the current terminal width via ioctl
func terminalWidth() -> Int {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 {
        return Int(ws.ws_col)
    }
    return 80
}

/// Team icon (unicode house, not emoji)
let teamIcon = "\u{2302}"
/// Powerline separator
let plSep = "\u{E0B0}"

