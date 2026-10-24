import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif


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

/// Formats Markdown to ANSI a line at a time, so a response can be shown as it streams in.
/// Tables are held back until their last row arrives, since column widths depend on all rows.
struct MarkdownFormatter {
    private var inCodeBlock = false
    private var tableBuffer: [String] = []

    /// Formats one complete line, returning the output lines it releases.
    mutating func line(_ line: String) -> [String] {
        var result: [String] = []
        // Flush table buffer if current line is not a table row
        if !tableBuffer.isEmpty && (inCodeBlock || !isTableRow(line)) {
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
            return result
        }

        if inCodeBlock {
            result.append("\(ansiDim)│\(ansiReset) \(line)")
            return result
        }

        // Collect table rows
        if isTableRow(line) {
            tableBuffer.append(line)
            return result
        }

        // Headers
        if line.hasPrefix("### ") {
            result.append("\(ansiBold)\(ansiDim)\(String(line.dropFirst(4)))\(ansiReset)")
        } else if line.hasPrefix("## ") {
            result.append("\(ansiBold)\(String(line.dropFirst(3)))\(ansiReset)")
        } else if line.hasPrefix("# ") {
            result.append("\(ansiBold)\(ansiCyan)\(String(line.dropFirst(2)))\(ansiReset)")
        } else if line == "---" || line == "***" || line == "___" {
            result.append("\(ansiDim)────────────────────────────────\(ansiReset)")
        } else {
            // Bullet lists
            var processed = line
            if let range = processed.range(of: #"^(\s*)[*\-] "#, options: .regularExpression) {
                let indent = String(processed[processed.startIndex..<range.lowerBound])
                let rest = String(processed[range.upperBound...])
                processed = "\(indent)  • \(rest)"
            }
            result.append(applyInlineFormatting(processed))
        }
        return result
    }

    /// Releases anything held back at the end of the text.
    mutating func finish() -> [String] {
        var result: [String] = []
        if !tableBuffer.isEmpty {
            result.append(contentsOf: renderTable(tableBuffer))
            tableBuffer.removeAll()
        }
        // Close unclosed code block
        if inCodeBlock {
            result.append("\(ansiDim)└──────────────────────────────\(ansiReset)")
            inCodeBlock = false
        }
        return result
    }
}

// Helper to format basic Markdown to ANSI
func formatMarkdown(_ text: String) -> String {
    var formatter = MarkdownFormatter()
    var result: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        result += formatter.line(String(line))
    }
    result += formatter.finish()
    return result.joined(separator: "\r\n")
}
