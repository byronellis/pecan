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

    // Memory-only configuration state
    private var inMemoryProviders: [ProviderConfig] = []
    
    // Sub-navigation inside providers screen
    private enum SubScreen {
        case list
        case edit(Int)
        case addCustom
    }
    private var subScreen: SubScreen = .list
    private var listSelectedIndex: Int = 0

    // Form editing state variables
    private var formFields: [String] = []
    private var formFieldIndex: Int = 0
    private var formEditingField: Int? = nil // Index of text field being edited
    private var formEditBuffer: String = ""
    private var formError: String = ""

    // Values of the provider currently being edited
    private var editID: String = ""
    private var editType: String = ""
    private var editURL: String = ""
    private var editKey: String = ""
    private var editHF: String = ""
    private var editEnabled: Bool = false

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
        // Open settings store (transient in-memory)
        do {
            try await SettingsStore.shared.open()
        } catch {
            print("Failed to open settings store: \(error)")
            exit(1)
        }

        // Initialize in-memory configuration state
        let existing = (try? await SettingsStore.shared.allProviders()) ?? []
        inMemoryProviders = []
        
        // 1. Add "Local MLX Models"
        if let mlx = existing.first(where: { $0.id == "mlx" }) {
            inMemoryProviders.append(mlx)
        } else {
            inMemoryProviders.append(ProviderConfig(id: "mlx", type: "mlx", url: "http://127.0.0.1:8080/v1", enabled: false))
        }
        
        // 2. Add "Fireworks.ai"
        if let fireworks = existing.first(where: { $0.id == "fireworks" }) {
            inMemoryProviders.append(fireworks)
        } else {
            inMemoryProviders.append(ProviderConfig(id: "fireworks", type: "fireworks", url: "https://api.fireworks.ai/inference/v1", enabled: false))
        }
        
        // 3. Add "Huggingface"
        if let hf = existing.first(where: { $0.id == "huggingface" }) {
            inMemoryProviders.append(hf)
        } else {
            inMemoryProviders.append(ProviderConfig(id: "huggingface", type: "huggingface", url: "https://api-inference.huggingface.co/v1", enabled: false))
        }
        
        // 4. Add custom OpenAI providers
        for p in existing {
            if p.id != "mlx" && p.id != "fireworks" && p.id != "huggingface" {
                inMemoryProviders.append(p)
            }
        }

        enableRawMode()
        // Enter alternate screen buffer and hide cursor
        print("\u{1B}[?1049h\u{1B}[?25l", terminator: "")
        fflush(stdout)
        
        defer {
            // Exit alternate screen buffer and show cursor
            print("\u{1B}[?1049l\u{1B}[?25h", terminator: "")
            disableRawMode()
            fflush(stdout)
        }

        updateSize()
        render()

        while !shouldExit {
            if let key = nextKey() {
                var handled = false
                
                if splitLayout.activePane == .mainPanel {
                    handled = await handleMainPanelKey(key)
                }
                
                if !handled {
                    handled = await splitLayout.handleKey(key)
                    if handled && splitLayout.activePane == .sidebar {
                        subScreen = .list
                        listSelectedIndex = 0
                    }
                }
                
                if !handled {
                    switch key {
                    case .ctrlC:
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
            termRows = Int(ws.ws_row) - 1 // Subtract 1 to guarantee no cursor wrap scrolling
            termCols = Int(ws.ws_col)
        } else {
            termRows = 23
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
            if let key = p.apiKey, !key.isEmpty {
                yaml += "    api_key: keychain\n"
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
        // Retrieve currently persistent providers to see what needs deletion
        let existing = (try? await SettingsStore.shared.allProviders()) ?? []
        let existingIDs = Set(existing.map { $0.id })
        let inMemoryIDs = Set(inMemoryProviders.map { $0.id })
        
        let toDelete = existingIDs.subtracting(inMemoryIDs)
        for id in toDelete {
            try? await SettingsStore.shared.deleteProvider(id: id)
            KeychainHelper.delete(key: id)
        }
        
        // Write the configured settings back to SQLite DB and Keychain
        for p in inMemoryProviders {
            // Write API key to Keychain if it's set and not the placeholder "keychain"
            if let key = p.apiKey, !key.isEmpty, key != "keychain" {
                _ = KeychainHelper.set(key: p.id, value: key)
            }
            
            let hasKey = (p.apiKey != nil && !p.apiKey!.isEmpty)
            let dbKey = hasKey ? "keychain" : nil
            
            let config = ProviderConfig(
                id: p.id,
                type: p.type,
                url: p.url,
                apiKey: dbKey,
                huggingfaceRepo: p.huggingfaceRepo,
                contextWindowOverride: p.contextWindowOverride,
                requestTimeout: p.requestTimeout,
                useStreaming: p.useStreaming,
                enabled: p.enabled
            )
            try? await SettingsStore.shared.upsertProvider(config)
        }

        let defaultModel = try? await SettingsStore.shared.globalDefault()
        let yaml = serializeToYAML(providers: inMemoryProviders, defaultModel: defaultModel)
        let path = ProxyConfig.configFilePath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            // ignore
        }
        shouldExit = true
    }

    private func cancelAndFinish() async {
        shouldExit = true
    }

    // MARK: - Main Panel Handlers

    private func handleMainPanelKey(_ key: InputKey) async -> Bool {
        let selectedID = sidebarMenu.selectedIndex.map { sidebarMenu.items[$0].id }
        guard selectedID == "providers" else { return false }
        
        switch subScreen {
        case .list:
            switch key {
            case .arrowDown:
                listSelectedIndex = (listSelectedIndex + 1) % (inMemoryProviders.count + 1)
                return true
            case .arrowUp:
                listSelectedIndex = (listSelectedIndex - 1 + inMemoryProviders.count + 1) % (inMemoryProviders.count + 1)
                return true
            case .enter:
                if listSelectedIndex < inMemoryProviders.count {
                    enterEditForm(index: listSelectedIndex)
                } else {
                    enterAddForm()
                }
                return true
            case .escape:
                splitLayout.activePane = .sidebar
                return true
            default:
                break
            }
        case .edit(let idx):
            return await handleFormKey(key, isNew: false, index: idx)
        case .addCustom:
            return await handleFormKey(key, isNew: true, index: nil)
        }
        return false
    }

    private func handleFormKey(_ key: InputKey, isNew: Bool, index: Int?) async -> Bool {
        if formEditingField != nil {
            switch key {
            case .enter:
                applyEditBuffer()
                return true
            case .escape:
                formEditingField = nil
                formEditBuffer = ""
                return true
            case .character(let c):
                formEditBuffer.append(c)
                return true
            case .backspace:
                if !formEditBuffer.isEmpty {
                    formEditBuffer.removeLast()
                }
                return true
            default:
                break
            }
            return true
        }
        
        switch key {
        case .arrowDown:
            formFieldIndex = (formFieldIndex + 1) % formFields.count
            return true
        case .arrowUp:
            formFieldIndex = (formFieldIndex - 1 + formFields.count) % formFields.count
            return true
        case .escape:
            formError = ""
            subScreen = .list
            return true
        case .enter:
            await handleFormEnter(isNew: isNew, index: index)
            return true
        default:
            break
        }
        return false
    }

    private func enterEditForm(index: Int) {
        let p = inMemoryProviders[index]
        editID = p.id
        editType = p.type
        editURL = p.url ?? ""
        editKey = p.apiKey ?? ""
        editHF = p.huggingfaceRepo ?? ""
        editEnabled = p.enabled
        
        formFieldIndex = 0
        formEditingField = nil
        formEditBuffer = ""
        formError = ""
        
        switch p.id {
        case "mlx":
            formFields = ["Model Dir / HF Repo", "Active Status", "Save Details", "Cancel"]
        case "fireworks", "huggingface":
            formFields = ["API Access Key", "Active Status", "Save Details", "Cancel"]
        default:
            formFields = ["ID / Name", "Base API URL", "API Access Key", "Active Status", "Save Details", "Delete Provider", "Cancel"]
        }
        subScreen = .edit(index)
    }

    private func enterAddForm() {
        editID = ""
        editType = "openai"
        editURL = ""
        editKey = ""
        editHF = ""
        editEnabled = false
        
        formFieldIndex = 0
        formEditingField = nil
        formEditBuffer = ""
        formError = ""
        
        formFields = ["ID / Name", "Base API URL", "API Access Key", "Active Status", "Save Details", "Cancel"]
        subScreen = .addCustom
    }

    private func applyEditBuffer() {
        guard let fieldIdx = formEditingField else { return }
        let label = formFields[fieldIdx]
        
        if label.contains("ID / Name") {
            editID = formEditBuffer.trimmingCharacters(in: .whitespaces)
        } else if label.contains("Base API URL") {
            editURL = formEditBuffer.trimmingCharacters(in: .whitespaces)
        } else if label.contains("API Access Key") {
            editKey = formEditBuffer.trimmingCharacters(in: .whitespaces)
        } else if label.contains("Model Dir") {
            editHF = formEditBuffer.trimmingCharacters(in: .whitespaces)
        }
        
        formEditingField = nil
        formEditBuffer = ""
    }

    private func handleFormEnter(isNew: Bool, index: Int?) async {
        let label = formFields[formFieldIndex]
        
        if label.contains("Save Details") {
            formError = ""
            
            if editID.isEmpty {
                formError = "Provider ID is required."
                return
            }
            
            if editType == "mlx" {
                if editEnabled && editHF.isEmpty {
                    formError = "Model Dir/HF Repo is required to activate."
                    return
                }
            } else if editType == "fireworks" || editType == "huggingface" {
                if editEnabled && editKey.isEmpty {
                    formError = "API key is required to activate."
                    return
                }
            } else {
                if editURL.isEmpty {
                    formError = "Base API URL is required."
                    return
                }
                
                let exists = inMemoryProviders.enumerated().contains { (idx, p) in
                    p.id == editID && (index == nil || idx != index!)
                }
                if exists {
                    formError = "Provider ID already exists."
                    return
                }
            }
            
            let config = ProviderConfig(
                id: editID,
                type: editType,
                url: editURL.isEmpty ? nil : editURL,
                apiKey: editKey.isEmpty ? nil : editKey,
                huggingfaceRepo: editHF.isEmpty ? nil : editHF,
                contextWindowOverride: nil,
                requestTimeout: nil,
                useStreaming: true,
                enabled: editEnabled
            )
            
            if let idx = index {
                inMemoryProviders[idx] = config
            } else {
                inMemoryProviders.append(config)
            }
            
            subScreen = .list
            listSelectedIndex = 0
            
        } else if label.contains("Delete Provider") {
            if let idx = index {
                inMemoryProviders.remove(at: idx)
            }
            subScreen = .list
            listSelectedIndex = 0
            
        } else if label.contains("Cancel") {
            formError = ""
            subScreen = .list
            
        } else if label.contains("Active Status") {
            editEnabled = !editEnabled
            
        } else {
            startEditingField(index: formFieldIndex)
        }
    }

    private func startEditingField(index: Int) {
        formEditingField = index
        let label = formFields[index]
        if label.contains("ID / Name") {
            formEditBuffer = editID
        } else if label.contains("Base API URL") {
            formEditBuffer = editURL
        } else if label.contains("API Access Key") {
            formEditBuffer = editKey
        } else if label.contains("Model Dir") {
            formEditBuffer = editHF
        }
    }

    // MARK: - Rendering

    private func render() {
        buffer.clear(style: BIOSStyle.bgBlue + BIOSStyle.fgWhite)

        let w = termCols
        let h = termRows

        let sidebarW = max(28, w / 3)
        let mainW = w - sidebarW
        let splitH = h - 2

        let activePane = splitLayout.activePane

        // 1. Draw Sidebar Box
        let sidebarBoxStyle = (activePane == .sidebar) ? BIOSStyle.fgCyan + BIOSStyle.bold : BIOSStyle.fgGray
        buffer.drawBox(x: 0, y: 0, w: sidebarW, h: splitH, title: "CATEGORIES", borderStyle: .double, boxStyle: sidebarBoxStyle, titleStyle: sidebarBoxStyle)

        // Draw Sidebar Menu Items
        for (idx, item) in sidebarMenu.items.enumerated() {
            let isSelected = (sidebarMenu.selectedIndex == idx)
            
            let itemY: Int
            if item.isAction {
                if item.id == "cancel" {
                    itemY = splitH - 2
                } else {
                    itemY = splitH - 3
                }
            } else {
                itemY = 2 + idx
            }

            var style = BIOSStyle.fgWhite
            if isSelected {
                if activePane == .sidebar {
                    style = BIOSStyle.selection + BIOSStyle.bold
                } else {
                    style = BIOSStyle.bold + BIOSStyle.fgCyan
                }
            }

            let prefix = isSelected ? "▶ " : "  "
            buffer.writeString(x: 2, y: itemY, string: prefix, style: style)
            
            if !isSelected, let hk = item.hotkey {
                buffer.writeString(x: 4, y: itemY, string: "[", style: style)
                buffer.writeString(x: 5, y: itemY, string: String(hk), style: BIOSStyle.fgYellow + BIOSStyle.bold)
                buffer.writeString(x: 6, y: itemY, string: "] \(item.label)", style: style)
            } else if isSelected, let hk = item.hotkey {
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

        // 2. Draw Main Panel Box
        let mainBoxStyle = (activePane == .mainPanel) ? BIOSStyle.fgCyan + BIOSStyle.bold : BIOSStyle.fgGray
        
        let selectedID = sidebarMenu.selectedIndex.map { sidebarMenu.items[$0].id }
        let mainTitle: String
        switch selectedID {
        case "providers":
            switch subScreen {
            case .list:        mainTitle = "PROVIDERS CONFIGURATION"
            case .edit:        mainTitle = "EDIT PROVIDER DETAILS"
            case .addCustom:   mainTitle = "ADD CUSTOM PROVIDER"
            }
        case "save":      mainTitle = "SAVE & EXIT"
        case "cancel":    mainTitle = "CANCEL & EXIT"
        default:          mainTitle = "WELCOME"
        }
        
        buffer.drawBox(x: sidebarW, y: 0, w: mainW, h: splitH, title: mainTitle, borderStyle: .double, boxStyle: mainBoxStyle, titleStyle: mainBoxStyle)

        // Draw Main Panel Content
        let contentX = sidebarW + 2
        let contentY = 2
        let contentW = mainW - 4
        let contentH = splitH - 3

        switch selectedID {
        case "providers":
            renderProvidersScreen(contentX: contentX, contentY: contentY, contentW: contentW, contentH: contentH)
            
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

        // 3. Draw Help Bar at the bottom
        let helpY = h - 2
        let helpBar = " [↑/↓] Navigate   [Enter] Select   [Esc] Back   [P] Providers   [S] Save   [C] Cancel"
        buffer.writeString(x: 0, y: helpY, string: helpBar.padding(toLength: w, withPad: " ", startingAt: 0), style: BIOSStyle.reverse + BIOSStyle.bold)
        
        let credit = " Pecan UI Config Editor v2.0"
        buffer.writeString(x: 0, y: h - 1, string: credit.padding(toLength: w - 1, withPad: " ", startingAt: 0), style: BIOSStyle.fgGray)

        print(buffer.renderString(), terminator: "")
        fflush(stdout)
    }

    private func renderProvidersScreen(contentX: Int, contentY: Int, contentW: Int, contentH: Int) {
        switch subScreen {
        case .list:
            buffer.writeString(x: contentX, y: contentY, string: "Configure LLM Providers:", style: BIOSStyle.fgCyan + BIOSStyle.bold)
            
            for idx in 0..<(inMemoryProviders.count + 1) {
                let isSelected = (listSelectedIndex == idx) && (splitLayout.activePane == .mainPanel)
                let cursor = isSelected ? "▶ " : "  "
                
                var style = BIOSStyle.fgWhite
                if isSelected {
                    style = BIOSStyle.selection + BIOSStyle.bold
                }
                
                let y = contentY + 2 + idx
                
                if idx < inMemoryProviders.count {
                    let p = inMemoryProviders[idx]
                    let statusBadge = p.enabled ? "● Active  " : "○ Inactive"
                    let badgeStyle = p.enabled ? BIOSStyle.fgCyan + BIOSStyle.bold : BIOSStyle.fgGray
                    
                    buffer.writeString(x: contentX + 2, y: y, string: cursor, style: style)
                    buffer.writeString(x: contentX + 4, y: y, string: statusBadge, style: isSelected ? style : badgeStyle)
                    
                    let idStr = p.id.padding(toLength: 15, withPad: " ", startingAt: 0)
                    buffer.writeString(x: contentX + 16, y: y, string: idStr, style: style)
                    
                    let detail: String
                    if p.id == "mlx" {
                        detail = p.huggingfaceRepo.map { "model: \($0)" } ?? "mlx local"
                    } else if p.id == "fireworks" {
                        detail = "fireworks endpoint"
                    } else if p.id == "huggingface" {
                        detail = "huggingface endpoint"
                    } else {
                        detail = p.url ?? ""
                    }
                    let truncatedDetail = detail.count > (contentW - 30) ? String(detail.prefix(contentW - 33)) + "..." : detail
                    buffer.writeString(x: contentX + 32, y: y, string: truncatedDetail, style: isSelected ? style : BIOSStyle.fgGray)
                } else {
                    buffer.writeString(x: contentX + 2, y: y, string: cursor + "[+] Add Custom OpenAI Provider", style: style)
                }
            }
            
        case .edit, .addCustom:
            drawForm(contentX: contentX, contentY: contentY, contentW: contentW, contentH: contentH)
        }
    }

    private func drawForm(contentX: Int, contentY: Int, contentW: Int, contentH: Int) {
        buffer.writeString(x: contentX, y: contentY, string: "Edit Provider Parameters:", style: BIOSStyle.fgCyan + BIOSStyle.bold)
        
        for idx in 0..<formFields.count {
            let label = formFields[idx]
            let isSelected = (formFieldIndex == idx)
            let isEditingThis = (formEditingField == idx)
            
            let cursor = isSelected ? "▶ " : "  "
            
            var style = BIOSStyle.fgWhite
            if isSelected {
                style = BIOSStyle.selection + BIOSStyle.bold
            }
            
            let y = contentY + 2 + idx
            let labelPadded = label.padding(toLength: 22, withPad: " ", startingAt: 0)
            
            if label.contains("Save Details") || label.contains("Cancel") || label.contains("Delete Provider") {
                let display = isSelected ? "[ \(label) ]" : "  [\(label)]"
                buffer.writeString(x: contentX + 2, y: y, string: display, style: style)
            } else if label.contains("Active Status") {
                let valStr = editEnabled ? "Yes (Active)" : "No (Inactive)"
                let display = "\(labelPadded): \(valStr)"
                buffer.writeString(x: contentX + 2, y: y, string: cursor + display, style: style)
            } else {
                var valStr = ""
                if label.contains("ID / Name") {
                    valStr = editID
                } else if label.contains("Base API URL") {
                    valStr = editURL
                } else if label.contains("API Access Key") {
                    valStr = editKey.isEmpty ? "(empty)" : String(repeating: "•", count: min(editKey.count, 12))
                } else if label.contains("Model Dir") {
                    valStr = editHF
                }
                
                if isEditingThis {
                    let display = "\(labelPadded): \(formEditBuffer)█"
                    buffer.writeString(x: contentX + 2, y: y, string: cursor + display, style: BIOSStyle.fgYellow + BIOSStyle.bold)
                } else {
                    let display = "\(labelPadded): \(valStr.isEmpty ? "(empty)" : valStr)"
                    buffer.writeString(x: contentX + 2, y: y, string: cursor + display, style: style)
                }
            }
        }
        
        if !formError.isEmpty {
            buffer.writeString(x: contentX + 2, y: contentY + 2 + formFields.count + 1, string: "⚠ \(formError)", style: BIOSStyle.fgYellow + BIOSStyle.bold)
        }
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
