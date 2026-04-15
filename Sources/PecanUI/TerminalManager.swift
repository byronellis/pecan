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

    /// Current prompt character — replaces ❯ with spinning braille frames while throbbing.
    var currentPromptChar = "❯"
    var isThrobbing = false

    func startThrobber(message: String) {
        stopThrobberSync()
        isThrobbing = true
        let frames = Self.throbberFrames
        throbberTask = Task {
            var i = 0
            while !Task.isCancelled {
                currentPromptChar = frames[i % frames.count]
                if chromeVisible {
                    redrawPrompt()
                }
                i += 1
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    func stopThrobber() {
        stopThrobberSync()
    }

    private func stopThrobberSync() {
        guard throbberTask != nil else { return }
        throbberTask?.cancel()
        throbberTask = nil
        isThrobbing = false
        currentPromptChar = "❯"
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
        let pc = isThrobbing ? "\(ansiDim)\(currentPromptChar)\(ansiReset)" : "\(ansiCyan)\(promptChar)\(ansiReset)"
        print("\(pc) \(currentInputBuffer)\r", terminator: "\n")

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
