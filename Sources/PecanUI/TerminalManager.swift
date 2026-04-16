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
    var agentTabs: [AgentTabInfo] = []
    var chromeVisible = false
    var cursorChromeLine = 2
    var focusedTaskTitle: String?
    var projectName: String?
    var teamName: String?

    // Agent picker state
    var pickerVisible = false
    var pickerSelection = 0

    // Team picker state (status-bar takeover)
    var teamPickerVisible = false
    var teamPickerItems: [(key: String, displayName: String)] = []
    var teamPickerSelection = 0

    // MARK: - Throbber

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
                if chromeVisible { redrawPrompt() }
                i += 1
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    func stopThrobber() { stopThrobberSync() }

    private func stopThrobberSync() {
        guard throbberTask != nil else { return }
        throbberTask?.cancel()
        throbberTask = nil
        isThrobbing = false
        currentPromptChar = "❯"
    }

    // MARK: - Chrome state updates

    func updateAgentTabs(_ tabs: [AgentTabInfo]) {
        agentTabs = tabs
        if inputActive { redrawPrompt() }
    }

    /// Legacy shim — converts flat list to AgentTabInfo without team/unread info.
    func updateAgents(_ newAgents: [(name: String, isActive: Bool)]) {
        agentTabs = newAgents.map {
            AgentTabInfo(id: "", name: $0.name, teamKey: "", isActive: $0.isActive, hasUnread: false)
        }
    }

    func updateFocusedTask(_ title: String?) {
        focusedTaskTitle = title
        if inputActive { redrawPrompt() }
    }

    func updateProjectTeam(project: String?, team: String?) {
        projectName = project
        teamName = team
        if inputActive { redrawPrompt() }
    }

    // MARK: - Status bar

    /// Build the tmux-style status bar: agents grouped by team, with unread `*` indicators.
    /// Within each group agents are numbered 1..N (Alt+1..9 hotkeys).
    private func buildStatusBar(width: Int) -> String {
        if teamPickerVisible {
            return buildTeamPickerBar(width: width)
        }

        // Group tabs: no-team first, then named teams in insertion order
        var noTeam: [AgentTabInfo] = []
        var teamOrder: [String] = []
        var teamGroups: [String: [AgentTabInfo]] = [:]
        for tab in agentTabs {
            if tab.teamKey.isEmpty {
                noTeam.append(tab)
            } else {
                if teamGroups[tab.teamKey] == nil {
                    teamOrder.append(tab.teamKey)
                    teamGroups[tab.teamKey] = []
                }
                teamGroups[tab.teamKey]!.append(tab)
            }
        }

        var segments: [(text: String, visLen: Int)] = []

        func tabSegment(_ tab: AgentTabInfo, index: Int) -> (text: String, visLen: Int) {
            let label = tab.hasUnread ? "\(index):\(tab.name)*" : "\(index):\(tab.name)"
            let visLen = label.count + 2  // one space each side
            if tab.isActive {
                return ("\u{1B}[1m\u{1B}[46m \(label) \(ansiReset)", visLen)
            } else {
                return ("\(ansiDim) \(label) \(ansiReset)", visLen)
            }
        }

        func separator() -> (text: String, visLen: Int) {
            ("  \(ansiDim)┃\(ansiReset)  ", 5)
        }

        var idx = 1

        // No-team agents
        for tab in noTeam {
            segments.append(tabSegment(tab, index: idx))
            idx += 1
        }

        // Named-team groups
        for teamKey in teamOrder {
            guard let tabs = teamGroups[teamKey], !tabs.isEmpty else { continue }
            if !segments.isEmpty { segments.append(separator()) }
            // Team label
            let teamLabel = "\(ansiDim)\(teamKey):\(ansiReset)"
            segments.append((teamLabel, teamKey.count + 1))
            idx = 1  // reset per team
            for tab in tabs {
                segments.append(tabSegment(tab, index: idx))
                idx += 1
            }
        }

        var visLen = segments.reduce(0) { $0 + $1.visLen }
        var result = segments.map(\.text).joined()

        // Right side: project + task (dim)
        var right = ""
        var rightLen = 0
        if let proj = projectName {
            right = "  \(teamIcon) \(proj)"
            rightLen = proj.count + 4
        }
        if let task = focusedTaskTitle, !task.isEmpty {
            let extra = "  \(task)"
            if visLen + rightLen + extra.count + 2 < width {
                right += extra
                rightLen += extra.count
            }
        }

        let padding = max(0, width - visLen - rightLen)
        let rightStr = right.isEmpty ? "" : "\(ansiDim)\(right)\(ansiReset)"
        return result + String(repeating: " ", count: padding) + rightStr
    }

    private func buildTeamPickerBar(width: Int) -> String {
        var parts: [String] = []
        var visLen = 0

        let header = "\(ansiDim)Team:\(ansiReset) "
        parts.append(header)
        visLen += 6

        let hotkeys = "123456789abcdefghijklmnopqrstuvwxyz"
        for (i, item) in teamPickerItems.enumerated() {
            guard i < hotkeys.count else { break }
            let key = hotkeys[hotkeys.index(hotkeys.startIndex, offsetBy: i)]
            let label = "\(key):\(item.displayName)"
            if i == teamPickerSelection {
                parts.append("\u{1B}[1m\u{1B}[46m \(label) \(ansiReset)")
            } else {
                parts.append("\(ansiDim) \(label) \(ansiReset)")
            }
            visLen += label.count + 2
        }

        let hint = "  \(ansiDim)Enter/key=select  Esc=cancel\(ansiReset)"
        let hintLen = 30
        let padding = max(0, width - visLen - hintLen)
        return parts.joined() + String(repeating: " ", count: padding) + hint
    }

    // MARK: - Chrome rendering

    func drawChrome() {
        let width = terminalWidth()
        let separator = "\(ansiDim)\(String(repeating: "─", count: width))\(ansiReset)"
        print(separator + "\r", terminator: "\n")

        let pc = isThrobbing ? "\(ansiDim)\(currentPromptChar)\(ansiReset)" : "\(ansiCyan)\(promptChar)\(ansiReset)"
        print("\(pc) \(currentInputBuffer)\r", terminator: "\n")
        print(buildStatusBar(width: width), terminator: "")

        let promptVisibleWidth = 2 + currentInputBuffer.count
        let promptLines = max(1, (promptVisibleWidth + width - 1) / width)
        let charOffset = 2 + cursorPosition
        let cursorRow = charOffset / width
        let cursorCol = charOffset % width
        let linesUp = promptLines - cursorRow
        print("\r\u{1B}[\(linesUp)A", terminator: "")
        if cursorCol > 0 { print("\u{1B}[\(cursorCol)C", terminator: "") }
        fflush(stdout)

        chromeVisible = true
        cursorChromeLine = cursorRow + 2
    }

    func clearChrome() {
        guard chromeVisible else { return }
        let linesUp = cursorChromeLine - 1
        if linesUp > 0 {
            print("\r\u{1B}[\(linesUp)A\u{1B}[J", terminator: "")
        } else {
            print("\r\u{1B}[J", terminator: "")
        }
        fflush(stdout)
        chromeVisible = false
    }

    // MARK: - Agent picker (Tab key)

    private var pickerRows: [(teamHeader: String?, tab: AgentTabInfo?, hotkey: Character?, agentIndex: Int)] {
        var rows: [(teamHeader: String?, tab: AgentTabInfo?, hotkey: Character?, agentIndex: Int)] = []
        let hotkeys = "0123456789abcdefghijklmnopqrstuvwxyz"
        var hotkeyIdx = 0

        var noTeam: [AgentTabInfo] = []
        var teamOrder: [String] = []
        var teamGroups: [String: [AgentTabInfo]] = [:]
        for tab in agentTabs {
            if tab.teamKey.isEmpty { noTeam.append(tab) }
            else {
                if teamGroups[tab.teamKey] == nil { teamOrder.append(tab.teamKey); teamGroups[tab.teamKey] = [] }
                teamGroups[tab.teamKey]!.append(tab)
            }
        }

        for tab in noTeam {
            guard hotkeyIdx < hotkeys.count else { break }
            let key = hotkeys[hotkeys.index(hotkeys.startIndex, offsetBy: hotkeyIdx)]
            rows.append((nil, tab, key, hotkeyIdx))
            hotkeyIdx += 1
        }
        for teamKey in teamOrder {
            guard let tabs = teamGroups[teamKey] else { continue }
            rows.append((teamKey, nil, nil, -1))
            for tab in tabs {
                guard hotkeyIdx < hotkeys.count else { break }
                let key = hotkeys[hotkeys.index(hotkeys.startIndex, offsetBy: hotkeyIdx)]
                rows.append((nil, tab, key, hotkeyIdx))
                hotkeyIdx += 1
            }
        }
        return rows
    }

    private var pickerLineCount: Int {
        let rows = pickerRows
        let headerRows = rows.filter { $0.teamHeader != nil }.count
        let agentRows = min(rows.filter { $0.tab != nil }.count, 36)
        return agentRows + headerRows + 3  // +3: title + blank + footer
    }

    func showAgentPicker() {
        guard !agentTabs.isEmpty else { return }
        clearChrome()
        pickerVisible = true
        if let activeIdx = agentTabs.firstIndex(where: { $0.isActive }) {
            pickerSelection = activeIdx
        } else {
            pickerSelection = 0
        }
        drawPicker()
    }

    private func drawPicker() {
        let rows = pickerRows
        print("\r\n\(ansiDim)── Select Agent ──\(ansiReset)\r", terminator: "\n")
        var agentIdx = 0
        for row in rows {
            if let header = row.teamHeader {
                print("  \(ansiDim)── \(header) ──\(ansiReset)\r", terminator: "\n")
            } else if let tab = row.tab, let key = row.hotkey {
                let isSelected = (row.agentIndex == pickerSelection)
                let unreadMark = tab.hasUnread ? " \(ansiDim)*\(ansiReset)" : ""
                if isSelected {
                    print("  \u{1B}[46m\u{1B}[1m \(key)  \(tab.name) \(ansiReset)\(unreadMark)\r", terminator: "\n")
                } else {
                    let marker = tab.isActive ? "\(ansiCyan) ← \(ansiReset)" : "   "
                    print("  \(ansiDim)\(key)\(ansiReset)  \(tab.name)\(marker)\(unreadMark)\r", terminator: "\n")
                }
                agentIdx += 1
            }
        }
        print("\(ansiDim)↑↓/key to select · Enter to confirm · Esc to cancel\(ansiReset)", terminator: "")
        fflush(stdout)
    }

    func redrawPicker() {
        let lines = pickerLineCount
        print("\r\u{1B}[\(lines)A\u{1B}[J", terminator: "")
        fflush(stdout)
        drawPicker()
    }

    func pickerMoveUp() {
        if pickerSelection > 0 { pickerSelection -= 1; redrawPicker() }
    }

    func pickerMoveDown() {
        let maxIdx = min(agentTabs.count, 36) - 1
        if pickerSelection < maxIdx { pickerSelection += 1; redrawPicker() }
    }

    func dismissPicker() {
        guard pickerVisible else { return }
        pickerVisible = false
        let lines = pickerLineCount
        print("\r\u{1B}[\(lines)A\u{1B}[J", terminator: "")
        fflush(stdout)
    }

    // MARK: - Team picker (status-bar takeover)

    func showTeamPicker(teams: [(key: String, displayName: String)]) {
        teamPickerItems = teams
        teamPickerSelection = 0
        teamPickerVisible = true
        if chromeVisible { redrawPrompt() }
    }

    func teamPickerMoveLeft() {
        if teamPickerSelection > 0 { teamPickerSelection -= 1; redrawPrompt() }
    }

    func teamPickerMoveRight() {
        if teamPickerSelection < teamPickerItems.count - 1 { teamPickerSelection += 1; redrawPrompt() }
    }

    func dismissTeamPicker() {
        guard teamPickerVisible else { return }
        teamPickerVisible = false
        if chromeVisible { redrawPrompt() }
    }

    func selectedTeamKey() -> String? {
        guard teamPickerSelection < teamPickerItems.count else { return nil }
        return teamPickerItems[teamPickerSelection].key
    }

    // MARK: - Output

    func printOutput(_ text: String) {
        stopThrobberSync()
        clearChrome()
        print("\r\u{1B}[K", terminator: "")
        print(text + "\r", terminator: "\n")
        if inputActive { drawChrome() }
    }

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

    func printSystem(_ text: String) {
        stopThrobberSync()
        clearChrome()
        print("\r\u{1B}[K", terminator: "")
        print("\(ansiDim)\(text)\(ansiReset)\r", terminator: "\n")
        if inputActive { drawChrome() }
    }

    // MARK: - Input editing

    func setInputActive(_ active: Bool) {
        inputActive = active
        if active { drawChrome() } else { clearChrome() }
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
        if cursorPosition > 0 { cursorPosition -= 1; redrawPrompt() }
    }

    func moveCursorRight() {
        if cursorPosition < currentInputBuffer.count { cursorPosition += 1; redrawPrompt() }
    }

    var killBuffer = ""

    func moveCursorToStart() {
        if cursorPosition > 0 { cursorPosition = 0; redrawPrompt() }
    }

    func moveCursorToEnd() {
        if cursorPosition < currentInputBuffer.count { cursorPosition = currentInputBuffer.count; redrawPrompt() }
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
        while newPos > 0 {
            let idx = currentInputBuffer.index(currentInputBuffer.startIndex, offsetBy: newPos - 1)
            if currentInputBuffer[idx] != " " { break }
            newPos -= 1
        }
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
