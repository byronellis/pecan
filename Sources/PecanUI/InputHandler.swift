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
            case .escape:
                let buf = await TerminalManager.shared.currentInputBuffer
                if buf.isEmpty {
                    // ESC with empty buffer — signal interrupt to outer loop
                    await TerminalManager.shared.setInputActive(false)
                    print("\r\u{1B}[K", terminator: "")
                    fflush(stdout)
                    return "\u{00}"
                } else {
                    // ESC with text — clear the input line
                    await TerminalManager.shared.clearInput()
                }
            case .unknown:
                break
            }
        } else {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
}

