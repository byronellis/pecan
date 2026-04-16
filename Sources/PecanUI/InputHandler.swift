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

enum InputKey {
    case ctrlC
    case ctrlD
    case ctrlA
    case ctrlE
    case ctrlK
    case ctrlU
    case ctrlW
    case ctrlY
    case ctrlB
    case ctrlF
    case tab
    case enter
    case backspace
    case delete
    case escape
    case arrowLeft
    case arrowRight
    case arrowUp
    case arrowDown
    case alt(Character)   // Alt+printable (ESC + char, detected by tight timing)
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
        // Peek for follow-up byte: spin ~1ms to distinguish bare ESC from Alt+key.
        // Alt sequences (ESC + char) arrive within microseconds; human presses take >100ms.
        var peekChar: Character? = nil
        for _ in 0..<2000 {
            if keyPressed() { peekChar = readChar(); break }
        }
        guard let next1 = peekChar else {
            return .escape  // bare ESC
        }
        if next1 == "[" {
            let next2 = readChar()
            switch next2 {
            case "A": return .arrowUp
            case "B": return .arrowDown
            case "C": return .arrowRight
            case "D": return .arrowLeft
            case "1":
                // Could be ESC[1;3x — Alt+Arrow from some terminals
                let next3 = readChar()
                if next3 == ";" {
                    let next4 = readChar()
                    if next4 == "3" {
                        let next5 = readChar()
                        switch next5 {
                        case "C": return .alt(Character(UnicodeScalar(UInt8(ascii: "f"))))  // Alt+Right → treat as Alt+f (forward team)
                        case "D": return .alt(Character(UnicodeScalar(UInt8(ascii: "b"))))  // Alt+Left → treat as Alt+b (backward team)
                        default: break
                        }
                    }
                }
                return .unknown(ascii)
            case "3":
                let next3 = readChar()
                if next3 == "~" { return .delete }
                return .unknown(ascii)
            default:
                return .unknown(ascii)
            }
        } else if let altAscii = next1.asciiValue, altAscii >= 32 {
            // ESC + printable char = Alt+key
            return .alt(next1)
        }
        return .escape
    case 32...126:
        return .character(char)
    default:
        if char.isASCII == false { return .character(char) }
        return .unknown(ascii)
    }
}

// MARK: - Agent Picker (Tab key)

func handleAgentPicker(sessionState: SessionState) async -> String? {
    await TerminalManager.shared.showAgentPicker()

    let hotkeys = "0123456789abcdefghijklmnopqrstuvwxyz"
    let agentCount = await TerminalManager.shared.agentTabs.count

    while true {
        if let key = nextKey() {
            switch key {
            case .escape, .tab:
                await TerminalManager.shared.dismissPicker()
                return nil
            case .enter:
                let selection = await TerminalManager.shared.pickerSelection
                let tabs = await TerminalManager.shared.agentTabs
                await TerminalManager.shared.dismissPicker()
                return selection < tabs.count ? tabs[selection].id : nil
            case .arrowUp, .ctrlB:
                await TerminalManager.shared.pickerMoveUp()
            case .arrowDown, .ctrlF:
                await TerminalManager.shared.pickerMoveDown()
            case .character(let c):
                if let idx = hotkeys.firstIndex(of: c) {
                    let i = hotkeys.distance(from: hotkeys.startIndex, to: idx)
                    if i < agentCount {
                        let tabs = await TerminalManager.shared.agentTabs
                        await TerminalManager.shared.dismissPicker()
                        return i < tabs.count ? tabs[i].id : nil
                    }
                }
            case .ctrlC:
                await TerminalManager.shared.dismissPicker()
                return nil
            default: break
            }
        } else {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - Team Picker (Alt+t)

/// Shows the team picker in the status bar and returns the selected team key, or nil if cancelled.
func handleTeamPicker(sessionState: SessionState) async -> String? {
    let teams = await sessionState.teamList()
    guard !teams.isEmpty else { return nil }

    await TerminalManager.shared.showTeamPicker(teams: teams)

    let hotkeys = "123456789abcdefghijklmnopqrstuvwxyz"

    while true {
        if let key = nextKey() {
            switch key {
            case .escape:
                await TerminalManager.shared.dismissTeamPicker()
                return nil
            case .alt(let c) where c == "t":
                await TerminalManager.shared.dismissTeamPicker()
                return nil
            case .ctrlC:
                await TerminalManager.shared.dismissTeamPicker()
                return nil
            case .enter:
                let teamKey = await TerminalManager.shared.selectedTeamKey()
                await TerminalManager.shared.dismissTeamPicker()
                return teamKey
            case .arrowLeft, .ctrlB:
                await TerminalManager.shared.teamPickerMoveLeft()
            case .arrowRight, .ctrlF:
                await TerminalManager.shared.teamPickerMoveRight()
            case .character(let c):
                if let idx = hotkeys.firstIndex(of: c) {
                    let i = hotkeys.distance(from: hotkeys.startIndex, to: idx)
                    let items = await TerminalManager.shared.teamPickerItems
                    if i < items.count {
                        await TerminalManager.shared.dismissTeamPicker()
                        return items[i].key
                    }
                }
            default: break
            }
        } else {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - Agent switching helper

/// Switch the active agent to `id`, clear its unread, replay buffered output, refresh chrome.
func switchToAgent(id: String, sessionState: SessionState) async {
    await sessionState.setActive(id)
    let tabs = await sessionState.agentTabList()
    await TerminalManager.shared.updateAgentTabs(tabs)
    let focusedTitle = await sessionState.getActiveFocusedTask()
    await TerminalManager.shared.updateFocusedTask(focusedTitle)
    let projectDisplay = await sessionState.getActiveProjectName()
    let teamDisplay = await sessionState.getActiveTeamName()
    await TerminalManager.shared.updateProjectTeam(project: projectDisplay, team: teamDisplay)

    let buffered = await sessionState.drainBuffer(id)  // also clears unread
    if !buffered.isEmpty {
        for rawText in buffered {
            if let rendered = renderAgentOutput(rawText) {
                await TerminalManager.shared.printOutput(rendered)
            }
        }
    }
    await TerminalManager.shared.redrawPrompt()
}

// MARK: - Command History

actor CommandHistory {
    static let shared = CommandHistory()

    private var history: [String: [String]] = [:]
    private var browseIndex: [String: Int] = [:]
    private var savedInput: [String: String] = [:]

    func add(_ command: String, sessionID: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if history[sessionID]?.last == trimmed { return }
        history[sessionID, default: []].append(trimmed)
        browseIndex.removeValue(forKey: sessionID)
        savedInput.removeValue(forKey: sessionID)
    }

    func navigateUp(sessionID: String, currentInput: String) -> String? {
        let entries = history[sessionID] ?? []
        guard !entries.isEmpty else { return nil }
        let idx: Int
        if let current = browseIndex[sessionID] {
            idx = current - 1
        } else {
            savedInput[sessionID] = currentInput
            idx = entries.count - 1
        }
        guard idx >= 0 else { return nil }
        browseIndex[sessionID] = idx
        return entries[idx]
    }

    func navigateDown(sessionID: String) -> String? {
        guard let current = browseIndex[sessionID] else { return nil }
        let entries = history[sessionID] ?? []
        let idx = current + 1
        if idx >= entries.count {
            browseIndex.removeValue(forKey: sessionID)
            return savedInput.removeValue(forKey: sessionID) ?? ""
        }
        browseIndex[sessionID] = idx
        return entries[idx]
    }

    func resetBrowse(sessionID: String) {
        browseIndex.removeValue(forKey: sessionID)
        savedInput.removeValue(forKey: sessionID)
    }
}

// MARK: - Main input loop

func readInputLine(sessionState: SessionState) async -> String? {
    await TerminalManager.shared.setInputActive(true)

    while true {
        if let key = nextKey() {
            switch key {

            // MARK: Control keys
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
                if let selectedID = await handleAgentPicker(sessionState: sessionState) {
                    await switchToAgent(id: selectedID, sessionState: sessionState)
                }
                await TerminalManager.shared.redrawPrompt()

            case .enter:
                let text = await TerminalManager.shared.getAndClearInput()
                await TerminalManager.shared.setInputActive(false)
                if let sid = await sessionState.getActiveID() {
                    await CommandHistory.shared.add(text, sessionID: sid)
                }
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
            case .arrowUp:
                if let sid = await sessionState.getActiveID() {
                    let cur = await TerminalManager.shared.currentInputBuffer
                    if let entry = await CommandHistory.shared.navigateUp(sessionID: sid, currentInput: cur) {
                        await TerminalManager.shared.setInputBuffer(entry)
                    }
                }
            case .arrowDown:
                if let sid = await sessionState.getActiveID() {
                    if let entry = await CommandHistory.shared.navigateDown(sessionID: sid) {
                        await TerminalManager.shared.setInputBuffer(entry)
                    }
                }
            case .escape:
                let buf = await TerminalManager.shared.currentInputBuffer
                if buf.isEmpty {
                    await TerminalManager.shared.setInputActive(false)
                    print("\r\u{1B}[K", terminator: "")
                    fflush(stdout)
                    return "\u{00}"
                } else {
                    await TerminalManager.shared.clearInput()
                }

            // MARK: Alt keys — agent and team navigation
            case .alt(let c):
                switch c {
                case "n":
                    // Next agent within current team
                    if let nextID = await sessionState.nextAgentInTeam() {
                        await switchToAgent(id: nextID, sessionState: sessionState)
                    }
                case "p":
                    // Previous agent within current team
                    if let prevID = await sessionState.prevAgentInTeam() {
                        await switchToAgent(id: prevID, sessionState: sessionState)
                    }
                case "t":
                    // Team picker (status-bar takeover)
                    if let teamKey = await handleTeamPicker(sessionState: sessionState) {
                        if let agentID = await sessionState.agentForTeam(teamKey) {
                            await switchToAgent(id: agentID, sessionState: sessionState)
                        }
                    }
                case "1"..."9":
                    // Jump to Nth agent within current team (1-indexed)
                    let idx = Int(String(c))! - 1
                    if let agentID = await sessionState.agentByIndexInTeam(idx) {
                        await switchToAgent(id: agentID, sessionState: sessionState)
                    }
                default:
                    break
                }

            case .character(let c):
                await TerminalManager.shared.insertChar(c)

            default:
                break
            }
        } else {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
