import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ANSITerminal

// MARK: - Border Styles
struct BorderStyle: Sendable {
    let topLeft: String
    let topRight: String
    let bottomLeft: String
    let bottomRight: String
    let horizontal: String
    let vertical: String

    static let single = BorderStyle(
        topLeft: "┌", topRight: "┐",
        bottomLeft: "└", bottomRight: "┘",
        horizontal: "─", vertical: "│"
    )
    static let double = BorderStyle(
        topLeft: "╔", topRight: "╗",
        bottomLeft: "╚", bottomRight: "╝",
        horizontal: "═", vertical: "║"
    )
}

// MARK: - ANSI Color Constants for BIOS Look
enum BIOSStyle {
    static let bgBlue      = "\u{1B}[48;5;18m" // Dark blue background
    static let fgWhite     = "\u{1B}[38;5;15m" // Bright white foreground
    static let fgGray      = "\u{1B}[38;5;244m" // Dim gray
    static let fgYellow    = "\u{1B}[38;5;220m" // Bright yellow (for shortcuts/hotkeys)
    static let fgCyan      = "\u{1B}[38;5;81m"  // Cyan
    static let bgCyan      = "\u{1B}[48;5;81m"
    static let reverse     = "\u{1B}[7m"
    static let bold        = "\u{1B}[1m"
    static let dim         = "\u{1B}[2m"
    static let reset       = "\u{1B}[0m"
}

// MARK: - Double-Buffered Screen Cell
struct TUICell {
    var char: Character = " "
    var style: String = ""
    
    init(char: Character = " ", style: String = "") {
        self.char = char
        self.style = style
    }
}

// MARK: - TUI Screen Buffer
@MainActor
class TUIBuffer {
    private(set) var width: Int
    private(set) var height: Int
    private var cells: [TUICell]

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.cells = Array(repeating: TUICell(), count: self.width * self.height)
    }

    func resize(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.cells = Array(repeating: TUICell(), count: self.width * self.height)
    }

    func clear(style: String = "") {
        for i in 0..<cells.count {
            cells[i] = TUICell(char: " ", style: style)
        }
    }

    func set(x: Int, y: Int, char: Character, style: String = "") {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        cells[y * width + x] = TUICell(char: char, style: style)
    }

    func writeString(x: Int, y: Int, string: String, style: String = "") {
        var currentX = x
        for char in string {
            set(x: currentX, y: y, char: char, style: style)
            currentX += 1
        }
    }

    func writeStringCentered(x: Int, y: Int, w: Int, string: String, style: String = "") {
        let textLen = string.count
        let startX = x + max(0, (w - textLen) / 2)
        writeString(x: startX, y: y, string: string, style: style)
    }

    func drawBox(x: Int, y: Int, w: Int, h: Int, title: String? = nil, borderStyle: BorderStyle = .single, boxStyle: String = "", titleStyle: String = "") {
        guard w > 1, h > 1 else { return }

        // Draw corners
        set(x: x, y: y, char: Character(borderStyle.topLeft), style: boxStyle)
        set(x: x + w - 1, y: y, char: Character(borderStyle.topRight), style: boxStyle)
        set(x: x, y: y + h - 1, char: Character(borderStyle.bottomLeft), style: boxStyle)
        set(x: x + w - 1, y: y + h - 1, char: Character(borderStyle.bottomRight), style: boxStyle)

        // Draw horizontal borders
        for i in 1..<(w - 1) {
            set(x: x + i, y: y, char: Character(borderStyle.horizontal), style: boxStyle)
            set(x: x + i, y: y + h - 1, char: Character(borderStyle.horizontal), style: boxStyle)
        }

        // Draw vertical borders
        for j in 1..<(h - 1) {
            set(x: x, y: y + j, char: Character(borderStyle.vertical), style: boxStyle)
            set(x: x + w - 1, y: y + j, char: Character(borderStyle.vertical), style: boxStyle)
        }

        // Draw title
        if let title = title {
            let maxTitleW = w - 4
            let truncatedTitle = title.count > maxTitleW ? String(title.prefix(maxTitleW)) : title
            writeString(x: x + 2, y: y, string: " \(truncatedTitle) ", style: titleStyle)
        }
    }

    /// Renders the buffer contents to a single string with cursor reset to top-left.
    func renderString() -> String {
        var output = ""
        output += "\u{1B}[H" // Move to 1,1
        
        for y in 0..<height {
            var currentStyle = ""
            for x in 0..<width {
                let cell = cells[y * width + x]
                if cell.style != currentStyle {
                    output += BIOSStyle.reset + cell.style
                    currentStyle = cell.style
                }
                output += String(cell.char)
            }
            if !currentStyle.isEmpty {
                output += BIOSStyle.reset
            }
            if y < height - 1 {
                output += "\r\n"
            }
        }
        return output
    }
}

// MARK: - Reusable Menu Item
struct TUIMenuItem {
    let id: String
    let label: String
    let hotkey: Character?     // Shortcut key, e.g., 'p'
    let isAction: Bool         // true if it's an action (like Save/Cancel) rather than configuration category
    let action: (() async -> Void)?

    init(id: String, label: String, hotkey: Character? = nil, isAction: Bool = false, action: (() async -> Void)? = nil) {
        self.id = id
        self.label = label
        self.hotkey = hotkey
        self.isAction = isAction
        self.action = action
    }
}

// MARK: - Reusable Menu
@MainActor
class TUIMenu {
    var items: [TUIMenuItem] = []
    var selectedIndex: Int? = nil // nil means welcome screen / nothing highlighted yet

    init(items: [TUIMenuItem] = []) {
        self.items = items
    }

    func moveDown() {
        guard !items.isEmpty else { return }
        if let current = selectedIndex {
            selectedIndex = (current + 1) % items.count
        } else {
            selectedIndex = 0
        }
    }

    func moveUp() {
        guard !items.isEmpty else { return }
        if let current = selectedIndex {
            selectedIndex = (current - 1 + items.count) % items.count
        } else {
            selectedIndex = items.count - 1
        }
    }

    func selectFirstNonAction() {
        selectedIndex = items.firstIndex(where: { !$0.isAction }) ?? 0
    }

    func findIndex(byHotkey char: Character) -> Int? {
        let lower = char.lowercased().first
        return items.firstIndex(where: {
            if let hk = $0.hotkey {
                return hk.lowercased().first == lower
            }
            return false
        })
    }
}

// MARK: - Active Pane State
enum TUIActivePane {
    case sidebar
    case mainPanel
}

// MARK: - Reusable Split Layout Container
@MainActor
class TUISplitLayout {
    var activePane: TUIActivePane = .sidebar
    var sidebarMenu: TUIMenu
    
    init(sidebarMenu: TUIMenu) {
        self.sidebarMenu = sidebarMenu
    }

    /// Handles keyboard events for split pane navigation.
    /// Returns true if the key was handled.
    func handleKey(_ key: InputKey) async -> Bool {
        switch activePane {
        case .sidebar:
            switch key {
            case .arrowDown:
                sidebarMenu.moveDown()
                return true
            case .arrowUp:
                sidebarMenu.moveUp()
                return true
            case .enter:
                if let idx = sidebarMenu.selectedIndex {
                    let item = sidebarMenu.items[idx]
                    if item.isAction {
                        if let action = item.action {
                            await action()
                        }
                    } else {
                        // Enter on category option goes to main panel
                        activePane = .mainPanel
                    }
                } else {
                    // Enter when nothing is selected: select the first option
                    sidebarMenu.selectFirstNonAction()
                }
                return true
            case .character(let c):
                if let idx = sidebarMenu.findIndex(byHotkey: c) {
                    sidebarMenu.selectedIndex = idx
                    let item = sidebarMenu.items[idx]
                    if item.isAction {
                        if let action = item.action {
                            await action()
                        }
                    } else {
                        // Selecting via hotkey directly focuses the main panel
                        activePane = .mainPanel
                    }
                    return true
                }
            default:
                break
            }
        case .mainPanel:
            switch key {
            case .escape:
                activePane = .sidebar
                return true
            default:
                break
            }
        }
        return false
    }
}
