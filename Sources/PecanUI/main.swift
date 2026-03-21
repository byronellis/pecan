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

// ANSI helpers
let ansiReset = "\u{001B}[0m"
let ansiBold = "\u{001B}[1m"
let ansiDim = "\u{001B}[2m"
let ansiItalic = "\u{001B}[3m"
let ansiCyan = "\u{001B}[36m"
let ansiGreen = "\u{001B}[32m"
let ansiBoldOff = "\u{001B}[22m"
let ansiItalicOff = "\u{001B}[23m"
let ansiDimOff = "\u{001B}[22m"

/// Check if a line looks like a markdown table row (starts and ends with |, or starts with |)
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
let ansiUserInputBg = "\u{001B}[48;5;236m"
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

actor TerminalManager {
    static let shared = TerminalManager()

    static let throbberFrames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]

    var currentInputBuffer = ""
    var cursorPosition = 0
    var throbberTask: Task<Void, Never>?
    var inputActive = false

    // Chrome state
    var agents: [(name: String, isActive: Bool)] = []
    var chromeVisible = false
    /// Which chrome line the cursor is on: 2 = prompt, 3 = status bar
    var cursorChromeLine = 2
    /// Currently focused task title for the active agent
    var focusedTaskTitle: String?
    /// Project and team names for breadcrumb display
    var projectName: String?
    var teamName: String?

    // Agent picker state
    var pickerVisible = false
    var pickerSelection = 0

    // MARK: - Throbber

    func startThrobber(message: String) {
        stopThrobberSync()
        // Draw separator + throbber line + status bar if not already visible
        if !chromeVisible && !agents.isEmpty {
            let width = terminalWidth()
            let separator = "\(ansiDim)\(String(repeating: "─", count: width))\(ansiReset)"
            print(separator + "\r", terminator: "\n")
            // Throbber line (placeholder)
            print("\r", terminator: "\n")
            // Status bar
            print(buildStatusBar(width: width), terminator: "")
            chromeVisible = true
            cursorChromeLine = 3
        }

        let frames = Self.throbberFrames
        throbberTask = Task {
            var i = 0
            while !Task.isCancelled {
                let frame = frames[i % frames.count]
                // Move up 1 line (to prompt/throbber line), clear it, print throbber, move back down
                print("\u{1B}[1A\r\u{1B}[K\(ansiDim)\(frame) \(message)\(ansiReset)\u{1B}[1B\r", terminator: "")
                fflush(stdout)
                i += 1
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    func stopThrobber() {
        stopThrobberSync()
    }

    private func stopThrobberSync() {
        if let task = throbberTask {
            task.cancel()
            throbberTask = nil
            print("\r\u{1B}[K", terminator: "")
            fflush(stdout)
        }
    }

    // MARK: - Chrome

    func updateAgents(_ newAgents: [(name: String, isActive: Bool)]) {
        agents = newAgents
    }

    func updateFocusedTask(_ title: String?) {
        focusedTaskTitle = title
        if inputActive {
            redrawPrompt()
        }
    }

    func updateProjectTeam(project: String?, team: String?) {
        projectName = project
        teamName = team
        if inputActive {
            redrawPrompt()
        }
    }

    /// Build the powerline status bar breadcrumb:
    /// pecan > project > team > agent > task  [N agents]
    /// Default project and team are hidden to reduce clutter.
    private func buildStatusBar(width: Int) -> String {
        let activeAgent = agents.first(where: { $0.isActive })
        let activeName = activeAgent?.name ?? "no agent"
        let count = agents.count

        // Build breadcrumb segments: home, optional project, optional team, agent name
        var breadcrumb = ""
        var breadcrumbLen = 0

        // Home flag
        let homeFlag = "\u{1B}[47m\u{1B}[30m \(teamIcon) \(ansiReset)"
        breadcrumb += homeFlag
        breadcrumbLen += 3

        // Project segment (if non-default)
        if let proj = projectName {
            let projSep = "\u{1B}[37m\u{1B}[45m\(plSep)\(ansiReset)"  // white fg on magenta bg
            let projSeg = "\u{1B}[45m\u{1B}[1m \(proj) \(ansiReset)"  // magenta bg
            breadcrumb += projSep + projSeg
            breadcrumbLen += 1 + proj.count + 2
        }

        // Team segment (if non-default)
        if let team = teamName {
            let teamSep: String
            if projectName != nil {
                teamSep = "\u{1B}[35m\u{1B}[44m\(plSep)\(ansiReset)"  // magenta fg on blue bg
            } else {
                teamSep = "\u{1B}[37m\u{1B}[44m\(plSep)\(ansiReset)"  // white fg on blue bg
            }
            let teamSeg = "\u{1B}[44m\u{1B}[1m \(team) \(ansiReset)"  // blue bg
            breadcrumb += teamSep + teamSeg
            breadcrumbLen += 1 + team.count + 2
        }

        // Agent segment (cyan)
        let agentSep: String
        if teamName != nil {
            agentSep = "\u{1B}[34m\u{1B}[46m\(plSep)\(ansiReset)"  // blue fg on cyan bg
        } else if projectName != nil {
            agentSep = "\u{1B}[35m\u{1B}[46m\(plSep)\(ansiReset)"  // magenta fg on cyan bg
        } else {
            agentSep = "\u{1B}[37m\u{1B}[46m\(plSep)\(ansiReset)"  // white fg on cyan bg
        }

        var cyanContent = " \(activeName) "
        var cyanVisibleLen = activeName.count + 2
        if let task = focusedTaskTitle, !task.isEmpty {
            let rightVisible = count > 1 ? "\(count)".count + 2 : 0
            let baseUsed = breadcrumbLen + 1 + cyanVisibleLen + 1 + rightVisible
            let availableForTask = width - baseUsed - 5
            if availableForTask > 5 {
                let truncated = task.count > availableForTask ? String(task.prefix(availableForTask - 1)) + "…" : task
                cyanContent = " \(activeName) │ \(truncated) "
                cyanVisibleLen = activeName.count + 2 + 3 + truncated.count + 1
            }
        }

        let agentSeg = "\u{1B}[46m\u{1B}[1m\(cyanContent)\(ansiReset)"
        let cyanToDefault = "\u{1B}[36m\(plSep)\(ansiReset)"

        breadcrumb += agentSep + agentSeg + cyanToDefault
        breadcrumbLen += 1 + cyanVisibleLen + 1

        let right = count > 1 ? "\(ansiDim)[\(count)]\(ansiReset)" : ""
        let rightVisible = count > 1 ? "\(count)".count + 2 : 0
        let padding = max(0, width - breadcrumbLen - rightVisible)

        return breadcrumb + String(repeating: " ", count: padding) + right
    }

    /// Render the chrome: separator + prompt (may wrap) + status bar
    func drawChrome() {
        let width = terminalWidth()

        // Line 1: dim separator
        let separator = "\(ansiDim)\(String(repeating: "─", count: width))\(ansiReset)"
        print(separator + "\r", terminator: "\n")

        // Line 2+: prompt with input buffer — may wrap across multiple visual rows
        print("\(ansiCyan)\(promptChar)\(ansiReset) \(currentInputBuffer)\r", terminator: "\n")

        // Last line: status bar
        print(buildStatusBar(width: width), terminator: "")

        // Compute how many visual rows the prompt occupies.
        // Visible prompt width = 2 ("❯ ") + input buffer length.
        let promptVisibleWidth = 2 + currentInputBuffer.count
        let promptLines = max(1, (promptVisibleWidth + width - 1) / width)

        // Find which visual row and column the cursor is on within the prompt.
        let charOffset = 2 + cursorPosition
        let cursorRow = charOffset / width   // 0-indexed row within prompt area
        let cursorCol = charOffset % width   // 0-indexed column

        // Move up from status bar to the cursor's row, then position column.
        let linesUp = promptLines - cursorRow  // always >= 1
        print("\r\u{1B}[\(linesUp)A", terminator: "")
        if cursorCol > 0 {
            print("\u{1B}[\(cursorCol)C", terminator: "")
        }
        fflush(stdout)

        chromeVisible = true
        // 1-indexed chrome row of cursor; clearChrome uses (cursorChromeLine - 1) to move back to sep.
        cursorChromeLine = cursorRow + 2
    }

    /// Clear the chrome from the terminal
    func clearChrome() {
        guard chromeVisible else { return }
        // Move up to separator line, then clear from cursor to end of screen
        let linesUp = cursorChromeLine - 1
        if linesUp > 0 {
            print("\r\u{1B}[\(linesUp)A\u{1B}[J", terminator: "")
        } else {
            print("\r\u{1B}[J", terminator: "")
        }
        fflush(stdout)
        chromeVisible = false
    }

    // MARK: - Agent Picker

    private var pickerLineCount: Int { min(agents.count, 36) + 3 }

    /// Show a picker overlay listing all agents with hotkeys
    func showAgentPicker() {
        guard !agents.isEmpty else { return }
        clearChrome()
        pickerVisible = true
        // Default selection to the currently active agent
        if let activeIdx = agents.firstIndex(where: { $0.isActive }) {
            pickerSelection = activeIdx
        } else {
            pickerSelection = 0
        }
        drawPicker()
    }

    /// Draw the picker list (assumes cursor is at the right starting position)
    private func drawPicker() {
        let hotkeys = "0123456789abcdefghijklmnopqrstuvwxyz"
        print("\r\n\(ansiDim)── Select Agent ──\(ansiReset)\r", terminator: "\n")
        for (i, agent) in agents.enumerated() {
            guard i < hotkeys.count else { break }
            let key = hotkeys[hotkeys.index(hotkeys.startIndex, offsetBy: i)]
            let isSelected = (i == pickerSelection)
            if isSelected {
                // Highlighted row: cyan bg
                print("  \u{1B}[46m\u{1B}[1m \(key)  \(agent.name) \(ansiReset)\r", terminator: "\n")
            } else {
                let marker = agent.isActive ? "\(ansiCyan) ← \(ansiReset)" : "   "
                print("  \(ansiDim)\(key)\(ansiReset)  \(agent.name)\(marker)\r", terminator: "\n")
            }
        }
        print("\(ansiDim)↑↓/key to select, Enter to confirm, Esc to cancel\(ansiReset)", terminator: "")
        fflush(stdout)
    }

    /// Redraw the picker in place
    func redrawPicker() {
        // Move up to start of picker and clear
        let lines = pickerLineCount
        print("\r\u{1B}[\(lines)A\u{1B}[J", terminator: "")
        fflush(stdout)
        // drawPicker prints a leading blank line, so we need to be 1 line above where it starts
        drawPicker()
    }

    func pickerMoveUp() {
        if pickerSelection > 0 {
            pickerSelection -= 1
            redrawPicker()
        }
    }

    func pickerMoveDown() {
        let maxIdx = min(agents.count, 36) - 1
        if pickerSelection < maxIdx {
            pickerSelection += 1
            redrawPicker()
        }
    }

    /// Dismiss the picker overlay
    func dismissPicker() {
        guard pickerVisible else { return }
        pickerVisible = false
        let lines = pickerLineCount
        // Move up to start and clear
        print("\r\u{1B}[\(lines)A\u{1B}[J", terminator: "")
        fflush(stdout)
    }

    // MARK: - Output

    /// Print agent/system output. This is the primary content — no prefix.
    func printOutput(_ text: String) {
        stopThrobberSync()
        clearChrome()
        print("\r\u{1B}[K", terminator: "")
        print(text + "\r", terminator: "\n")
        if inputActive {
            drawChrome()
        }
    }

    /// Echo user input with a distinctive background color
    func printUserInput(_ text: String) {
        stopThrobberSync()
        clearChrome()
        let width = terminalWidth()
        let content = " \(promptChar) \(text) "
        let padding = max(0, width - content.count)
        print("\r\u{1B}[K", terminator: "")
        print("\(ansiUserInputBg)\(content)\(String(repeating: " ", count: padding))\(ansiReset)\r", terminator: "\n")
        fflush(stdout)
    }

    /// Print a dim system/status message
    func printSystem(_ text: String) {
        stopThrobberSync()
        clearChrome()
        print("\r\u{1B}[K", terminator: "")
        print("\(ansiDim)\(text)\(ansiReset)\r", terminator: "\n")
        if inputActive {
            drawChrome()
        }
    }

    // MARK: - Input

    func setInputActive(_ active: Bool) {
        inputActive = active
        if active {
            drawChrome()
        } else {
            clearChrome()
        }
    }

    func redrawPrompt() {
        clearChrome()
        drawChrome()
    }

    func insertChar(_ char: Character) {
        let idx = currentInputBuffer.index(currentInputBuffer.startIndex, offsetBy: cursorPosition)
        currentInputBuffer.insert(char, at: idx)
        cursorPosition += 1
        redrawPrompt()
    }

    func backspace() {
        if cursorPosition > 0 {
            let idx = currentInputBuffer.index(currentInputBuffer.startIndex, offsetBy: cursorPosition - 1)
            currentInputBuffer.remove(at: idx)
            cursorPosition -= 1
            redrawPrompt()
        }
    }

    func moveCursorLeft() {
        if cursorPosition > 0 {
            cursorPosition -= 1
            redrawPrompt()
        }
    }

    func moveCursorRight() {
        if cursorPosition < currentInputBuffer.count {
            cursorPosition += 1
            redrawPrompt()
        }
    }

    // MARK: - Readline Editing

    /// Kill buffer for ^K/^U/^W + ^Y
    var killBuffer = ""

    func moveCursorToStart() {
        if cursorPosition > 0 {
            cursorPosition = 0
            redrawPrompt()
        }
    }

    func moveCursorToEnd() {
        if cursorPosition < currentInputBuffer.count {
            cursorPosition = currentInputBuffer.count
            redrawPrompt()
        }
    }

    func killToEnd() {
        guard cursorPosition < currentInputBuffer.count else { return }
        let idx = currentInputBuffer.index(currentInputBuffer.startIndex, offsetBy: cursorPosition)
        killBuffer = String(currentInputBuffer[idx...])
        currentInputBuffer = String(currentInputBuffer[..<idx])
        redrawPrompt()
    }

    func killToStart() {
        guard cursorPosition > 0 else { return }
        let idx = currentInputBuffer.index(currentInputBuffer.startIndex, offsetBy: cursorPosition)
        killBuffer = String(currentInputBuffer[..<idx])
        currentInputBuffer = String(currentInputBuffer[idx...])
        cursorPosition = 0
        redrawPrompt()
    }

    func killWordBackward() {
        guard cursorPosition > 0 else { return }
        var newPos = cursorPosition
        // Skip whitespace backward
        while newPos > 0 {
            let idx = currentInputBuffer.index(currentInputBuffer.startIndex, offsetBy: newPos - 1)
            if currentInputBuffer[idx] != " " { break }
            newPos -= 1
        }
        // Skip word chars backward
        while newPos > 0 {
            let idx = currentInputBuffer.index(currentInputBuffer.startIndex, offsetBy: newPos - 1)
            if currentInputBuffer[idx] == " " { break }
            newPos -= 1
        }
        let startIdx = currentInputBuffer.index(currentInputBuffer.startIndex, offsetBy: newPos)
        let endIdx = currentInputBuffer.index(currentInputBuffer.startIndex, offsetBy: cursorPosition)
        killBuffer = String(currentInputBuffer[startIdx..<endIdx])
        currentInputBuffer.removeSubrange(startIdx..<endIdx)
        cursorPosition = newPos
        redrawPrompt()
    }

    func yank() {
        guard !killBuffer.isEmpty else { return }
        let idx = currentInputBuffer.index(currentInputBuffer.startIndex, offsetBy: cursorPosition)
        currentInputBuffer.insert(contentsOf: killBuffer, at: idx)
        cursorPosition += killBuffer.count
        redrawPrompt()
    }

    func deleteForward() {
        if cursorPosition < currentInputBuffer.count {
            let idx = currentInputBuffer.index(currentInputBuffer.startIndex, offsetBy: cursorPosition)
            currentInputBuffer.remove(at: idx)
            redrawPrompt()
        }
    }

    func clearInput() {
        currentInputBuffer = ""
        cursorPosition = 0
        redrawPrompt()
    }

    func getAndClearInput() -> String {
        let text = currentInputBuffer
        currentInputBuffer = ""
        cursorPosition = 0
        return text
    }

    func setInputBuffer(_ text: String) {
        currentInputBuffer = text
        cursorPosition = text.count
        redrawPrompt()
    }
}

enum InputKey {
    case ctrlC
    case ctrlD
    case ctrlA  // beginning of line
    case ctrlE  // end of line
    case ctrlK  // kill to end of line
    case ctrlU  // kill to beginning of line
    case ctrlW  // kill word backward
    case ctrlY  // yank (paste kill buffer)
    case ctrlB  // back one char
    case ctrlF  // forward one char
    case tab
    case enter
    case backspace
    case delete // forward delete
    case escape
    case arrowLeft
    case arrowRight
    case arrowUp
    case arrowDown
    case character(Character)
    case unknown(UInt8)
}

func nextKey() -> InputKey? {
    guard keyPressed() else { return nil }
    let char = readChar()
    let ascii = char.asciiValue ?? 0

    switch ascii {
    case 1: return .ctrlA
    case 2: return .ctrlB
    case 3: return .ctrlC
    case 4: return .ctrlD
    case 5: return .ctrlE
    case 6: return .ctrlF
    case 9: return .tab
    case 10, 13: return .enter
    case 11: return .ctrlK
    case 21: return .ctrlU
    case 23: return .ctrlW
    case 25: return .ctrlY
    case 127: return .backspace
    case 27:
        // ESC sequence
        let next1 = readChar()
        if next1 == "[" {
            let next2 = readChar()
            switch next2 {
            case "A": return .arrowUp
            case "B": return .arrowDown
            case "C": return .arrowRight
            case "D": return .arrowLeft
            case "3":
                // Delete key: ESC [ 3 ~
                let next3 = readChar()
                if next3 == "~" { return .delete }
                return .unknown(ascii)
            default: return .unknown(ascii)
            }
        }
        return .escape
    case 32...126:
        return .character(char)
    default:
        // Attempt to pass through other printable characters (e.g. unicode)
        if char.isASCII == false {
            return .character(char)
        }
        return .unknown(ascii)
    }
}

/// Handle the agent picker interaction. Returns the index of selected agent, or nil if cancelled.
func handleAgentPicker() async -> Int? {
    await TerminalManager.shared.showAgentPicker()

    let hotkeys = "0123456789abcdefghijklmnopqrstuvwxyz"
    let agentCount = await TerminalManager.shared.agents.count

    while true {
        if let key = nextKey() {
            switch key {
            case .escape, .tab:
                await TerminalManager.shared.dismissPicker()
                return nil
            case .enter:
                let selection = await TerminalManager.shared.pickerSelection
                await TerminalManager.shared.dismissPicker()
                return selection
            case .arrowUp, .ctrlB:
                await TerminalManager.shared.pickerMoveUp()
            case .arrowDown, .ctrlF:
                await TerminalManager.shared.pickerMoveDown()
            case .character(let c):
                if let idx = hotkeys.firstIndex(of: c) {
                    let i = hotkeys.distance(from: hotkeys.startIndex, to: idx)
                    if i < agentCount {
                        await TerminalManager.shared.dismissPicker()
                        return i
                    }
                }
            case .ctrlC:
                await TerminalManager.shared.dismissPicker()
                return nil
            default:
                break
            }
        } else {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - Command History

actor CommandHistory {
    static let shared = CommandHistory()

    /// Per-session command history (sessionID -> entries, newest last)
    private var history: [String: [String]] = [:]
    /// Current browse index per session (nil = not browsing)
    private var browseIndex: [String: Int] = [:]
    /// Saved in-progress input when user starts browsing
    private var savedInput: [String: String] = [:]

    func add(_ command: String, sessionID: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Don't duplicate consecutive entries
        if history[sessionID]?.last == trimmed { return }
        history[sessionID, default: []].append(trimmed)
        // Reset browse position
        browseIndex.removeValue(forKey: sessionID)
        savedInput.removeValue(forKey: sessionID)
    }

    /// Move up in history. Returns the history entry to display, or nil if at top.
    func navigateUp(sessionID: String, currentInput: String) -> String? {
        let entries = history[sessionID] ?? []
        guard !entries.isEmpty else { return nil }

        let idx: Int
        if let current = browseIndex[sessionID] {
            idx = current - 1
        } else {
            // Starting to browse — save current input
            savedInput[sessionID] = currentInput
            idx = entries.count - 1
        }

        guard idx >= 0 else { return nil }
        browseIndex[sessionID] = idx
        return entries[idx]
    }

    /// Move down in history. Returns the entry to display, or the saved input if past the end.
    func navigateDown(sessionID: String) -> String? {
        guard let current = browseIndex[sessionID] else { return nil }
        let entries = history[sessionID] ?? []

        let idx = current + 1
        if idx >= entries.count {
            // Past the end — restore saved input
            browseIndex.removeValue(forKey: sessionID)
            let saved = savedInput.removeValue(forKey: sessionID) ?? ""
            return saved
        }
        browseIndex[sessionID] = idx
        return entries[idx]
    }

    func resetBrowse(sessionID: String) {
        browseIndex.removeValue(forKey: sessionID)
        savedInput.removeValue(forKey: sessionID)
    }
}

func readInputLine(sessionState: SessionState) async -> String? {
    await TerminalManager.shared.setInputActive(true)

    while true {
        if let key = nextKey() {
            switch key {
            case .ctrlC:
                await TerminalManager.shared.setInputActive(false)
                return nil
            case .ctrlD:
                let buf = await TerminalManager.shared.currentInputBuffer
                if buf.isEmpty {
                    await TerminalManager.shared.setInputActive(false)
                    return nil
                } else {
                    await TerminalManager.shared.deleteForward()
                }
            case .tab:
                // Show agent picker
                if let selectedIdx = await handleAgentPicker() {
                    let agents = await sessionState.allSessions()
                    if selectedIdx < agents.count {
                        let selected = agents[selectedIdx]
                        await sessionState.setActive(selected.id)
                        let agentList = await sessionState.agentList()
                        await TerminalManager.shared.updateAgents(agentList)
                        let focusedTitle = await sessionState.getActiveFocusedTask()
                        await TerminalManager.shared.updateFocusedTask(focusedTitle)
                    }
                }
                await TerminalManager.shared.redrawPrompt()
            case .enter:
                let text = await TerminalManager.shared.getAndClearInput()
                await TerminalManager.shared.setInputActive(false)
                // Save to history
                if let sid = await sessionState.getActiveID() {
                    await CommandHistory.shared.add(text, sessionID: sid)
                }
                // Clear the prompt line — caller will echo the input
                print("\r\u{1B}[K", terminator: "")
                fflush(stdout)
                return text
            case .backspace:
                await TerminalManager.shared.backspace()
            case .delete:
                await TerminalManager.shared.deleteForward()
            case .arrowLeft, .ctrlB:
                await TerminalManager.shared.moveCursorLeft()
            case .arrowRight, .ctrlF:
                await TerminalManager.shared.moveCursorRight()
            case .ctrlA:
                await TerminalManager.shared.moveCursorToStart()
            case .ctrlE:
                await TerminalManager.shared.moveCursorToEnd()
            case .ctrlK:
                await TerminalManager.shared.killToEnd()
            case .ctrlU:
                await TerminalManager.shared.killToStart()
            case .ctrlW:
                await TerminalManager.shared.killWordBackward()
            case .ctrlY:
                await TerminalManager.shared.yank()
            case .character(let c):
                await TerminalManager.shared.insertChar(c)
            case .arrowUp:
                if let sid = await sessionState.getActiveID() {
                    let currentBuf = await TerminalManager.shared.currentInputBuffer
                    if let entry = await CommandHistory.shared.navigateUp(sessionID: sid, currentInput: currentBuf) {
                        await TerminalManager.shared.setInputBuffer(entry)
                    }
                }
            case .arrowDown:
                if let sid = await sessionState.getActiveID() {
                    if let entry = await CommandHistory.shared.navigateDown(sessionID: sid) {
                        await TerminalManager.shared.setInputBuffer(entry)
                    }
                }
            case .escape, .unknown:
                break
            }
        } else {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
}

actor SessionState {
    struct Session {
        let id: String
        let name: String
        var projectName: String
        var teamName: String
    }

    /// Ordered list of sessions (insertion order)
    private var sessionOrder: [String] = []
    private var sessions: [String: Session] = [:]
    private var activeSessionID: String?
    /// sessionID -> focused task title
    private var focusedTasks: [String: String] = [:]
    /// Buffered raw output texts for non-active sessions (rendered on drain)
    private var outputBuffers: [String: [String]] = [:]
    /// Max buffered entries per session to prevent unbounded memory growth
    private let maxBufferEntries = 1000

    func addSession(id: String, name: String, projectName: String = "", teamName: String = "") {
        sessions[id] = Session(id: id, name: name, projectName: projectName, teamName: teamName)
        if !sessionOrder.contains(id) {
            sessionOrder.append(id)
        }
        activeSessionID = id
    }

    func getActiveProjectName() -> String? {
        guard let id = activeSessionID, let s = sessions[id] else { return nil }
        return s.projectName.isEmpty ? nil : s.projectName
    }

    func getActiveTeamName() -> String? {
        guard let id = activeSessionID, let s = sessions[id] else { return nil }
        // Hide "default" team
        if s.teamName.isEmpty || s.teamName == "default" { return nil }
        return s.teamName
    }

    func updateProjectTeam(sessionID: String, projectName: String, teamName: String) {
        guard var session = sessions[sessionID] else { return }
        session.projectName = projectName
        session.teamName = teamName
        sessions[sessionID] = session
    }

    func setActive(_ id: String) {
        if sessions[id] != nil {
            activeSessionID = id
        }
    }

    func setActiveByName(_ name: String) -> Bool {
        if let session = sessions.values.first(where: { $0.name == name }) {
            activeSessionID = session.id
            return true
        }
        return false
    }

    func getActiveID() -> String? {
        return activeSessionID
    }

    func getActiveName() -> String? {
        guard let id = activeSessionID else { return nil }
        return sessions[id]?.name
    }

    func allSessions() -> [Session] {
        return sessionOrder.compactMap { sessions[$0] }
    }

    func agentList() -> [(name: String, isActive: Bool)] {
        return sessionOrder.compactMap { id in
            guard let s = sessions[id] else { return nil }
            return (s.name, s.id == activeSessionID)
        }
    }

    func setFocusedTask(sessionID: String, title: String) {
        if title.isEmpty {
            focusedTasks.removeValue(forKey: sessionID)
        } else {
            focusedTasks[sessionID] = title
        }
    }

    func getActiveFocusedTask() -> String? {
        guard let id = activeSessionID else { return nil }
        return focusedTasks[id]
    }

    // Legacy compatibility
    func setSession(id: String, name: String) {
        addSession(id: id, name: name)
    }

    func getID() -> String? {
        return activeSessionID
    }

    func getAgentName() -> String? {
        guard let id = activeSessionID else { return nil }
        return sessions[id]?.name
    }

    func isActiveSession(_ sessionID: String) -> Bool {
        return sessionID == activeSessionID
    }

    func bufferOutput(_ sessionID: String, rawText: String) {
        if outputBuffers[sessionID] == nil {
            outputBuffers[sessionID] = []
        }
        outputBuffers[sessionID]!.append(rawText)
        if outputBuffers[sessionID]!.count > maxBufferEntries {
            outputBuffers[sessionID]!.removeFirst(outputBuffers[sessionID]!.count - maxBufferEntries)
        }
    }

    func drainBuffer(_ sessionID: String) -> [String] {
        return outputBuffers.removeValue(forKey: sessionID) ?? []
    }
}

func main() async throws {
    // Handle Ctrl+C (SIGINT)
    signal(SIGINT) { _ in
        print("\r\nExiting Pecan UI...\r")
        exit(0)
    }

    // Parse CLI arguments
    var cliProjectName: String? = nil
    var cliTeamName: String? = nil
    do {
        var i = 1
        while i < CommandLine.arguments.count {
            switch CommandLine.arguments[i] {
            case "--project":
                i += 1
                if i < CommandLine.arguments.count { cliProjectName = CommandLine.arguments[i] }
            case "--team":
                i += 1
                if i < CommandLine.arguments.count { cliTeamName = CommandLine.arguments[i] }
            default: break
            }
            i += 1
        }
    }

    // Load config just to verify we can parse ~/.pecan/config.yaml
    do {
        let config = try Config.load()
        print("Loaded config. Default model: \(config.defaultModel ?? config.models.first?.key ?? "unknown")\r", terminator: "\n")
    } catch {
        // Suppress warning if not setup yet
    }
    
    // Discover server port from status file
    let serverPort: Int
    do {
        let status = try ServerStatus.read()
        guard status.isAlive else {
            print("Error: server status file found but process \(status.pid) is not running. Start the server first.\r", terminator: "\n")
            exit(1)
        }
        serverPort = status.port
    } catch {
        print("Error: could not read server status file (.run/server.json): \(error)\r", terminator: "\n")
        print("Make sure the server is running (./dev_start.sh).\r", terminator: "\n")
        exit(1)
    }

    // Setup gRPC Client
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let channel = try GRPCChannelPool.with(
        target: .host("127.0.0.1", port: serverPort),
        transportSecurity: .plaintext,
        eventLoopGroup: group
    ) { config in
        config.keepalive = ClientConnectionKeepalive(
            interval: .seconds(15),
            timeout: .seconds(10),
            permitWithoutCalls: true,
            maximumPingsWithoutData: 0
        )
        config.connectionBackoff = ConnectionBackoff(
            initialBackoff: 1.0,
            maximumBackoff: 60.0,
            multiplier: 1.6,
            jitter: 0.2
        )
    }

    let client = Pecan_ClientServiceAsyncClient(channel: channel)

    // Open Bidirectional Stream
    let call = client.makeStreamEventsCall()

    // UI Setup
    clearScreen()
    moveTo(1, 1)
    print("🥜 Pecan Interactive UI".bold + "\r", terminator: "\n")
    print("Connecting to server at 127.0.0.1:\(serverPort)...\r\n", terminator: "\n")
    
    let sessionState = SessionState()

    // Start a task to listen for server messages
    let receiverTask = Task {
        do {
            for try await message in call.responseStream {
                switch message.payload {
                case .sessionStarted(let started):
                    let name = started.agentName.isEmpty ? "agent" : started.agentName
                    await sessionState.addSession(id: started.sessionID, name: name, projectName: started.projectName, teamName: started.teamName)
                    let agents = await sessionState.agentList()
                    await TerminalManager.shared.updateAgents(agents)
                    // Update breadcrumb with project/team
                    let projectDisplay = await sessionState.getActiveProjectName()
                    let teamDisplay = await sessionState.getActiveTeamName()
                    await TerminalManager.shared.updateProjectTeam(project: projectDisplay, team: teamDisplay)
                    var startMsg = "Session started: \(name) (\(started.sessionID))"
                    if !started.projectName.isEmpty {
                        startMsg += " [project: \(started.projectName)]"
                    }
                    if !started.teamName.isEmpty && started.teamName != "default" {
                        startMsg += " [team: \(started.teamName)]"
                    }
                    await TerminalManager.shared.printSystem(startMsg)

                case .agentOutput(let output):
                    let isActive = await sessionState.isActiveSession(output.sessionID)

                    if isActive {
                        // Render live — includes side effects like throbbers
                        if let data = output.text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                           let msgType = json["type"] {
                            // Start throbber for thinking/tool_call (side effect only for live view)
                            if msgType == "thinking" {
                                await TerminalManager.shared.startThrobber(message: "Thinking...")
                            } else if msgType == "tool_call" {
                                let toolName = json["name"] ?? "unknown"
                                if let rendered = renderAgentOutput(output.text) {
                                    await TerminalManager.shared.printOutput(rendered)
                                }
                                await TerminalManager.shared.startThrobber(message: "Running \(toolName)...")
                            } else if let rendered = renderAgentOutput(output.text) {
                                await TerminalManager.shared.printOutput(rendered)
                            }
                        } else if let rendered = renderAgentOutput(output.text) {
                            await TerminalManager.shared.printOutput(rendered)
                        }
                    } else {
                        // Buffer raw text for non-active sessions
                        await sessionState.bufferOutput(output.sessionID, rawText: output.text)
                    }

                case .approvalRequest(let req):
                    await TerminalManager.shared.printSystem("Tool Approval Required: \(req.toolName)\r\nArguments: \(req.argumentsJson)\r\nApprove? (y/n)")

                case .taskCompleted(let comp):
                    await TerminalManager.shared.printSystem("Task completed: \(comp.sessionID)")

                case .taskUpdate(let update):
                    await sessionState.setFocusedTask(sessionID: update.sessionID, title: update.focusedTaskTitle)
                    let focusedTitle = await sessionState.getActiveFocusedTask()
                    await TerminalManager.shared.updateFocusedTask(focusedTitle)

                case .sessionUpdate(let update):
                    await sessionState.updateProjectTeam(
                        sessionID: update.sessionID,
                        projectName: update.projectName,
                        teamName: update.teamName
                    )
                    // Refresh breadcrumbs if this is the active session
                    if await sessionState.getActiveID() == update.sessionID {
                        let projectDisplay = await sessionState.getActiveProjectName()
                        let teamDisplay = await sessionState.getActiveTeamName()
                        await TerminalManager.shared.updateProjectTeam(project: projectDisplay, team: teamDisplay)
                    }

                case nil:
                    break
                }
            }
        } catch {
            await TerminalManager.shared.printSystem("Disconnected from server: \(error)")
        }
    }
    
    // Send an initial task to kick things off
    var initialMsg = Pecan_ClientMessage()
    var startTask = Pecan_StartTaskRequest()
    startTask.initialPrompt = "Initialize new session"
    if let p = cliProjectName { startTask.projectName = p }
    if let t = cliTeamName { startTask.teamName = t }
    initialMsg.startTask = startTask
    try await call.requestStream.send(initialMsg)
    
    // Input Loop
    while true {
        guard let line = await readInputLine(sessionState: sessionState) else { break }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed == "/quit" || trimmed == "exit" {
            break
        }

        if !trimmed.isEmpty {
            await TerminalManager.shared.printUserInput(trimmed)

            // /help — show available commands
            if trimmed == "/help" {
                let help = """
                \(ansiBold)Commands\(ansiReset)
                  \(ansiCyan)/new\(ansiReset)              Spawn a new agent
                  \(ansiCyan)/fork\(ansiReset)             Fork current agent (copies context & shares)
                  \(ansiCyan)/agents\(ansiReset)            List all agents
                  \(ansiCyan)/switch\(ansiReset) \(ansiDim)<name>\(ansiReset)    Switch to agent by name
                  \(ansiCyan)/share\(ansiReset) \(ansiDim)[-rw] <path>[:<guest>]\(ansiReset)
                                    Share a host directory with the agent
                  \(ansiCyan)/unshare\(ansiReset) \(ansiDim)<path>\(ansiReset)  Remove a shared directory
                  \(ansiCyan)/quit\(ansiReset)             Exit Pecan

                \(ansiBold)Tasks\(ansiReset) \(ansiDim)(/t = /task, /ts = /tasks)\(ansiReset)
                  \(ansiCyan)/t\(ansiReset) \(ansiDim)<text>\(ansiReset)          Create a new task
                  \(ansiCyan)/ts\(ansiReset)                List all tasks
                  \(ansiCyan)/ts\(ansiReset) \(ansiDim)<status>\(ansiReset)       List tasks by status
                  \(ansiCyan)/t #\(ansiReset)\(ansiDim)<id>\(ansiReset)           Show task details
                  \(ansiCyan)/t #\(ansiReset)\(ansiDim)<id>\(ansiReset) \(ansiDim)<field> <value>\(ansiReset)
                                    Update task field
                  \(ansiDim)Scope: /t:t = team, /t:p = project, /t:t:name = specific team\(ansiReset)

                \(ansiBold)Projects\(ansiReset) \(ansiDim)(/p = /project)\(ansiReset)
                  \(ansiCyan)/p\(ansiReset)                Show current project
                  \(ansiCyan)/p:list\(ansiReset)            List all projects
                  \(ansiCyan)/p:create\(ansiReset) \(ansiDim)<name> [dir]\(ansiReset)
                                    Create a new project
                  \(ansiCyan)/p:switch\(ansiReset) \(ansiDim)<name>\(ansiReset)   Switch to a project

                \(ansiBold)Teams\(ansiReset)
                  \(ansiCyan)/team\(ansiReset)              Show current team
                  \(ansiCyan)/team:list\(ansiReset)         List teams in project
                  \(ansiCyan)/team:create\(ansiReset) \(ansiDim)<name>\(ansiReset) Create a new team
                  \(ansiCyan)/team:join\(ansiReset) \(ansiDim)<name>\(ansiReset)   Join a team
                  \(ansiCyan)/team:leave\(ansiReset)        Leave current team

                \(ansiBold)Keys\(ansiReset)
                  \(ansiCyan)↑\(ansiReset) / \(ansiCyan)↓\(ansiReset)            Command history (per agent)
                  \(ansiCyan)Tab\(ansiReset)               Agent picker (↑↓ or hotkey to select)
                  \(ansiCyan)^A\(ansiReset) / \(ansiCyan)^E\(ansiReset)          Beginning / end of line
                  \(ansiCyan)^K\(ansiReset) / \(ansiCyan)^U\(ansiReset)          Kill to end / start of line
                  \(ansiCyan)^W\(ansiReset)                Kill word backward
                  \(ansiCyan)^Y\(ansiReset)                Yank (paste killed text)
                """
                await TerminalManager.shared.printOutput(help)
                continue
            }

            // /agents — list all agents
            if trimmed == "/agents" {
                let agents = await sessionState.agentList()
                if agents.isEmpty {
                    await TerminalManager.shared.printSystem("No agents.")
                } else {
                    var lines = "\(ansiBold)Agents\(ansiReset)\r\n"
                    for agent in agents {
                        let marker = agent.isActive ? "\(ansiCyan) ← active\(ansiReset)" : ""
                        lines += "  \(agent.isActive ? "\(ansiBold)\(agent.name)\(ansiReset)" : "\(ansiDim)\(agent.name)\(ansiReset)")\(marker)\r\n"
                    }
                    await TerminalManager.shared.printOutput(lines)
                }
                continue
            }

            // /new — spawn a fresh agent
            if trimmed == "/new" {
                var msg = Pecan_ClientMessage()
                var startTask = Pecan_StartTaskRequest()
                startTask.initialPrompt = "Initialize new session"
                if let p = cliProjectName { startTask.projectName = p }
                if let t = cliTeamName { startTask.teamName = t }
                msg.startTask = startTask
                try await call.requestStream.send(msg)
                continue
            }

            // /fork — clone context+shares from current agent into new one
            if trimmed == "/fork" {
                guard let currentSid = await sessionState.getActiveID() else {
                    await TerminalManager.shared.printSystem("No active session to fork.")
                    continue
                }
                var msg = Pecan_ClientMessage()
                var startTask = Pecan_StartTaskRequest()
                startTask.initialPrompt = "Initialize forked session"
                startTask.forkSessionID = currentSid
                // Inherit project/team from the session being forked
                if let p = await sessionState.getActiveProjectName() {
                    startTask.projectName = p
                }
                if let t = await sessionState.getActiveTeamName() {
                    startTask.teamName = t
                }
                msg.startTask = startTask
                try await call.requestStream.send(msg)
                continue
            }

            // /switch <name> — switch active tab by agent name
            if trimmed.hasPrefix("/switch ") {
                let name = String(trimmed.dropFirst("/switch ".count)).trimmingCharacters(in: .whitespaces)
                if await sessionState.setActiveByName(name) {
                    let agents = await sessionState.agentList()
                    await TerminalManager.shared.updateAgents(agents)
                    // Update breadcrumbs to reflect the switched-to session's project/team
                    let projectDisplay = await sessionState.getActiveProjectName()
                    let teamDisplay = await sessionState.getActiveTeamName()
                    await TerminalManager.shared.updateProjectTeam(project: projectDisplay, team: teamDisplay)
                    let focusedTask = await sessionState.getActiveFocusedTask()
                    await TerminalManager.shared.updateFocusedTask(focusedTask)
                    await TerminalManager.shared.printSystem("Switched to \(name)")
                    // Replay any buffered output from while this agent was in the background
                    if let sid = await sessionState.getActiveID() {
                        let buffered = await sessionState.drainBuffer(sid)
                        if !buffered.isEmpty {
                            await TerminalManager.shared.printSystem("--- buffered output ---")
                            for rawText in buffered {
                                if let rendered = renderAgentOutput(rawText) {
                                    await TerminalManager.shared.printOutput(rendered)
                                }
                            }
                            await TerminalManager.shared.printSystem("--- end buffered output ---")
                        }
                    }
                } else {
                    let all = await sessionState.allSessions().map(\.name).joined(separator: ", ")
                    await TerminalManager.shared.printSystem("No agent named '\(name)'. Available: \(all)")
                }
                continue
            }

            guard let sid = await sessionState.getID() else {
                await TerminalManager.shared.printSystem("Waiting for session ID...")
                continue
            }

            var msg = Pecan_ClientMessage()
            var input = Pecan_TaskInput()
            input.sessionID = sid
            input.text = trimmed
            msg.userInput = input

            try await call.requestStream.send(msg)
        }
    }
    
    print("\r\nExiting Pecan UI...\r", terminator: "\n")
    
    // Cleanup
    call.requestStream.finish()
    receiverTask.cancel()
    
    try await channel.close().get()
    try await group.shutdownGracefully()
}

Task {
    do {
        try await main()
    } catch {
        print("Error: \(error)")
    }
    exit(0)
}

RunLoop.main.run()
