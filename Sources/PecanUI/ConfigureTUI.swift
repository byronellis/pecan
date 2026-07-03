import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ANSITerminal
import PecanSettings
import PecanServer

// MARK: - Interactive configuration TUI

@MainActor
public func runConfigureTUI() async {
    let tui = ConfigureTUI()
    await tui.run()
}

@MainActor
final class ConfigureTUI {
    private var shouldExit = false
    private var sidebarMenu = TUIMenu()
    private var splitLayout: TUISplitLayout!
    private var termRows: Int = 24
    private var termCols: Int = 80
    private var buffer = TUIBuffer(width: 80, height: 24)

    init() {
        let items = [
            TUIMenuItem(id: "providers", label: "Configure Providers", hotkey: "P", isAction: false),
            TUIMenuItem(id: "save", label: "Save and Finish", hotkey: "S", isAction: true, action: { [weak self] in
                await self?.saveAndFinish()
            }),
            TUIMenuItem(id: "cancel", label: "Cancel and Finish", hotkey: "C", isAction: true, action: { [weak self] in
                await self?.cancelAndFinish()
            })
        ]
        sidebarMenu = TUIMenu(items: items)
        splitLayout = TUISplitLayout(sidebarMenu: sidebarMenu)
    }

    func run() async {
        // Open settings store
        do {
            try await SettingsStore.shared.open()
        } catch {
            print("Failed to open settings store: \(error)")
            exit(1)
        }

        enableRawMode()
        print("\u{1B}[?25l", terminator: "") // hide cursor
        defer {
            print("\u{1B}[?25h", terminator: "") // show cursor
            disableRawMode()
            // Clear screen when leaving
            print("\u{1B}[2J\u{1B}[H", terminator: "")
            fflush(stdout)
        }

        updateSize()
        render()

        while !shouldExit {
            if let key = nextKey() {
                let handled = await splitLayout.handleKey(key)
                if !handled {
                    switch key {
                    case .ctrlC:
                        shouldExit = true
                    case .character(let c) where c == "q" || c == "Q":
                        shouldExit = true
                    default:
                        break
                    }
                }
                updateSize()
                render()
            } else {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    private func updateSize() {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            termRows = Int(ws.ws_row)
            termCols = Int(ws.ws_col)
        } else {
            termRows = 24
            termCols = 80
        }
        buffer.resize(width: termCols, height: termRows)
    }

    private func serializeToYAML(providers: [ProviderConfig], defaultModel: String?) -> String {
        var yaml = ""
        if let def = defaultModel, !def.isEmpty {
            yaml += "default_model: \(def)\n"
        }
        yaml += "providers:\n"
        for p in providers {
            yaml += "  \(p.id):\n"
            yaml += "    type: \(p.type)\n"
            if let url = p.url {
                yaml += "    url: \(url)\n"
            }
            if let key = p.apiKey {
                yaml += "    api_key: \(key)\n"
            }
            if let hf = p.huggingfaceRepo {
                yaml += "    huggingface_repo: \(hf)\n"
            }
            if let ctx = p.contextWindowOverride {
                yaml += "    context_window: \(ctx)\n"
            }
            if let timeout = p.requestTimeout {
                yaml += "    request_timeout: \(timeout)\n"
            }
            yaml += "    use_streaming: \(p.useStreaming)\n"
            yaml += "    enabled: \(p.enabled)\n"
        }
        return yaml
    }

    private func saveAndFinish() async {
        let providers = (try? await SettingsStore.shared.allProviders()) ?? []
        let defaultModel = try? await SettingsStore.shared.globalDefault()
        let yaml = serializeToYAML(providers: providers, defaultModel: defaultModel)
        let path = ProxyConfig.configFilePath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            // Silently ignore or handle failure
        }
        shouldExit = true
    }

    private func cancelAndFinish() async {
        shouldExit = true
    }

    private func render() {
        buffer.clear(style: BIOSStyle.bgBlue + BIOSStyle.fgWhite)

        let w = termCols
        let h = termRows

        // 1. Draw top header bar
        buffer.writeStringCentered(x: 0, y: 0, w: w, string: " 🥜 PECAN BIOS CONFIGURATION UTILITY 🥜 ", style: BIOSStyle.reverse + BIOSStyle.bold)

        // Calculate sizes
        let sidebarW = max(28, w / 3)
        let mainW = w - sidebarW
        let splitH = h - 3

        let activePane = splitLayout.activePane

        // 2. Draw Sidebar Box
        let sidebarBoxStyle = (activePane == .sidebar) ? BIOSStyle.fgCyan + BIOSStyle.bold : BIOSStyle.fgGray
        buffer.drawBox(x: 0, y: 1, w: sidebarW, h: splitH, title: "CATEGORIES", borderStyle: .double, boxStyle: sidebarBoxStyle, titleStyle: sidebarBoxStyle)

        // Draw Sidebar Menu Items
        for (idx, item) in sidebarMenu.items.enumerated() {
            let isSelected = (sidebarMenu.selectedIndex == idx)
            
            // Determine Y coordinate
            let itemY: Int
            if item.isAction {
                if item.id == "cancel" {
                    itemY = splitH - 2
                } else {
                    itemY = splitH - 3
                }
            } else {
                itemY = 3 + idx
            }

            // Determine Style
            var style = BIOSStyle.fgWhite
            if isSelected {
                if activePane == .sidebar {
                    style = BIOSStyle.reverse + BIOSStyle.bold + BIOSStyle.fgYellow
                } else {
                    style = BIOSStyle.bold + BIOSStyle.fgCyan
                }
            }

            // Write selection cursor prefix
            let prefix = isSelected ? "▶ " : "  "
            buffer.writeString(x: 2, y: itemY, string: prefix, style: style)
            
            // Highlight hotkey if item is not selected
            if !isSelected, let hk = item.hotkey {
                buffer.writeString(x: 4, y: itemY, string: "[", style: style)
                buffer.writeString(x: 5, y: itemY, string: String(hk), style: BIOSStyle.fgYellow + BIOSStyle.bold)
                buffer.writeString(x: 6, y: itemY, string: "] \(item.label)", style: style)
            } else if isSelected, let hk = item.hotkey {
                // If selected in reverse mode, keep yellow hotkey highlight visible
                if activePane == .sidebar {
                    buffer.writeString(x: 4, y: itemY, string: "[\(hk)] \(item.label)", style: style)
                } else {
                    buffer.writeString(x: 4, y: itemY, string: "[", style: style)
                    buffer.writeString(x: 5, y: itemY, string: String(hk), style: BIOSStyle.fgYellow + BIOSStyle.bold)
                    buffer.writeString(x: 6, y: itemY, string: "] \(item.label)", style: style)
                }
            } else {
                buffer.writeString(x: 4, y: itemY, string: item.label, style: style)
            }
        }

        // 3. Draw Main Panel Box
        let mainBoxStyle = (activePane == .mainPanel) ? BIOSStyle.fgCyan + BIOSStyle.bold : BIOSStyle.fgGray
        
        let selectedID = sidebarMenu.selectedIndex.map { sidebarMenu.items[$0].id }
        let mainTitle: String
        switch selectedID {
        case "providers": mainTitle = "PROVIDERS CONFIGURATION"
        case "save":      mainTitle = "SAVE & EXIT"
        case "cancel":    mainTitle = "CANCEL & EXIT"
        default:          mainTitle = "WELCOME"
        }
        
        buffer.drawBox(x: sidebarW, y: 1, w: mainW, h: splitH, title: mainTitle, borderStyle: .double, boxStyle: mainBoxStyle, titleStyle: mainBoxStyle)

        // Draw Main Panel Content
        let contentX = sidebarW + 2
        let contentY = 3
        let contentW = mainW - 4
        let contentH = splitH - 4

        switch selectedID {
        case "providers":
            let text = [
                "[ Not Yet Implemented ]",
                "",
                "This screen will allow you to configure,",
                "add, edit, and delete LLM providers.",
                "",
                "Press [ESC] to return to the Sidebar."
            ]
            drawTextCentered(text: text, x: contentX, y: contentY, w: contentW, h: contentH, style: BIOSStyle.fgWhite)
            
        case "save":
            let text = [
                "Save changes and write a new config.yaml.",
                "",
                "Press [Enter] to confirm and exit.",
                "Press [ESC] to return to the Sidebar."
            ]
            drawTextCentered(text: text, x: contentX, y: contentY, w: contentW, h: contentH, style: BIOSStyle.fgYellow + BIOSStyle.bold)
            
        case "cancel":
            let text = [
                "Discard changes and exit.",
                "Your config.yaml will not be modified.",
                "",
                "Press [Enter] to confirm and exit.",
                "Press [ESC] to return to the Sidebar."
            ]
            drawTextCentered(text: text, x: contentX, y: contentY, w: contentW, h: contentH, style: BIOSStyle.fgWhite)
            
        default:
            // Welcome screen
            let text = [
                "Welcome to Pecan Onboarding!",
                "",
                "This configuration utility helps you setup",
                "your AI providers (OpenAI, Anthropic, MLX, etc.)",
                "and set defaults for your pecan server.",
                "",
                "Use [↑/↓ Arrows] to navigate items in the sidebar.",
                "Press [Enter] to select and edit.",
                "",
                "Quick Shortcuts:",
                "  [P] Configure Providers",
                "  [S] Save and Finish",
                "  [C] Cancel and Finish"
            ]
            drawTextCentered(text: text, x: contentX, y: contentY, w: contentW, h: contentH, style: BIOSStyle.fgWhite)
        }

        // 4. Draw Help Bar at the bottom
        let helpY = h - 2
        let helpBar = " [↑/↓] Navigate   [Enter] Select   [Esc] Back   [P] Providers   [S] Save   [C] Cancel"
        buffer.writeString(x: 0, y: helpY, string: helpBar.padding(toLength: w, withPad: " ", startingAt: 0), style: BIOSStyle.reverse + BIOSStyle.bold)
        
        let credit = " Pecan UI Config Editor v2.0"
        buffer.writeString(x: 0, y: h - 1, string: credit.padding(toLength: w, withPad: " ", startingAt: 0), style: BIOSStyle.fgGray)

        print(buffer.renderString(), terminator: "")
        fflush(stdout)
    }

    private func drawTextCentered(text: [String], x: Int, y: Int, w: Int, h: Int, style: String = "") {
        let startY = y + max(0, (h - text.count) / 2)
        for (idx, line) in text.enumerated() {
            buffer.writeStringCentered(x: x, y: startY + idx, w: w, string: line, style: style)
        }
    }

    private func enableRawMode() {
        var t = termios()
        tcgetattr(STDIN_FILENO, &t)
        t.c_lflag &= ~(UInt(ECHO) | UInt(ICANON))
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
    }

    private func disableRawMode() {
        var t = termios()
        tcgetattr(STDIN_FILENO, &t)
        t.c_lflag |= UInt(ECHO) | UInt(ICANON)
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
    }
}
