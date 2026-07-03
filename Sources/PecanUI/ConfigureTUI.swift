import Foundation
import ANSITerminal
import PecanSettings
import PecanServer

// MARK: - Interactive configuration TUI

public func runConfigureTUI() async {
    do {
        try await SettingsStore.shared.open()
    } catch {
        print("Failed to open settings store: \(error)")
        exit(1)
    }
    let tui = ConfigureTUI()
    await tui.run()
}

// MARK: - Provider form models

private struct ProviderForm {
    var originalID: String?  // nil = new provider
    var id: String = ""
    var providerType: String = "openai"
    var url: String = ""
    var apiKey: String = ""
    var hfRepo: String = ""
    var contextWindowOverride: String = ""
    var requestTimeout: String = ""
    var useStreaming: Bool = true
    var enabled: Bool = true

    var isNew: Bool { originalID == nil }
    static let types = ["openai", "mlx", "fireworks", "anthropic", "mock"]

    mutating func cycleType() {
        let idx = Self.types.firstIndex(of: providerType) ?? 0
        providerType = Self.types[(idx + 1) % Self.types.count]
        
        if id.isEmpty || Self.types.contains(id) {
            id = providerType
        }
        
        if url.isEmpty || url.contains("api.openai.com") || url.contains("api.fireworks.ai") || url.contains("api.anthropic.com") || url.contains("127.0.0.1:8080") {
            switch providerType {
            case "openai": url = "https://api.openai.com/v1"
            case "fireworks": url = "https://api.fireworks.ai/inference/v1"
            case "anthropic": url = "https://api.anthropic.com/v1"
            case "mlx": url = "http://127.0.0.1:8080/v1"
            default: url = ""
            }
        }
    }

    func toConfig() -> ProviderConfig? {
        let trimID = id.trimmingCharacters(in: .whitespaces)
        guard !trimID.isEmpty else { return nil }
        let trimURL = url.trimmingCharacters(in: .whitespaces)
        let trimKey = apiKey.trimmingCharacters(in: .whitespaces)
        let trimRepo = hfRepo.trimmingCharacters(in: .whitespaces)
        let trimCtx = contextWindowOverride.trimmingCharacters(in: .whitespaces)
        let trimTimeout = requestTimeout.trimmingCharacters(in: .whitespaces)
        return ProviderConfig(
            id: trimID,
            type: providerType,
            url: trimURL.isEmpty ? nil : trimURL,
            apiKey: trimKey.isEmpty ? nil : trimKey,
            huggingfaceRepo: trimRepo.isEmpty ? nil : trimRepo,
            contextWindowOverride: Int(trimCtx),
            requestTimeout: Double(trimTimeout),
            useStreaming: useStreaming,
            enabled: enabled
        )
    }

    static func from(_ p: ProviderConfig) -> ProviderForm {
        ProviderForm(
            originalID: p.id,
            id: p.id,
            providerType: p.type,
            url: p.url ?? "",
            apiKey: p.apiKey ?? "",
            hfRepo: p.huggingfaceRepo ?? "",
            contextWindowOverride: p.contextWindowOverride.map { String($0) } ?? "",
            requestTimeout: p.requestTimeout.map { String(format: "%.0f", $0) } ?? "",
            useStreaming: p.useStreaming,
            enabled: p.enabled
        )
    }
}

// MARK: - ConfigureTUI

@MainActor
final class ConfigureTUI {
    private var providers: [ProviderConfig] = []
    private var cachedModels: [RemoteModelInfo] = []
    private var personaModels: [(persona: String, modelKey: String)] = []
    private var globalDefault: String = ""
    private var selectedRow: Int = 0

    private enum Screen { case main, form, modelPicker }
    private var screen: Screen = .main
    private var shouldExit = false

    // Form state
    private var form = ProviderForm()
    private var formSelectedField: Int = 0
    private var formEditingField: Int? = nil
    private var formEditBuffer: String = ""
    private var formError: String = ""

    // Model picker state
    private var pickerProviderID: String = ""
    private var pickerSelectedRow: Int = 0

    private var statusMessage: String = ""

    private let formFieldLabels = ["ID/Name", "Type", "URL", "API Key", "HF Repo", "Ctx Window", "Timeout", "Streaming", "Enabled", "Save", "Cancel"]
    private let formFieldCount = 11

    func run() async {
        await loadSettings()
        enableRawMode()
        hideCursor()
        defer { showCursor(); disableRawMode(); clearScreen() }

        render()
        while !shouldExit {
            guard let key = readKey() else { continue }
            switch screen {
            case .main:        await handleMainKey(key)
            case .form:        await handleFormKey(key)
            case .modelPicker: await handlePickerKey(key)
            }
            if !shouldExit { render() }
        }
    }

    // MARK: - Main Screen

    private func handleMainKey(_ key: String) async {
        switch key {
        case "q", "\u{1B}":
            shouldExit = true
        case "j", "\u{1B}[B":
            if selectedRow < providers.count - 1 { selectedRow += 1 }
        case "k", "\u{1B}[A":
            if selectedRow > 0 { selectedRow -= 1 }
        case "\r", "\n":
            guard !providers.isEmpty, selectedRow < providers.count else { return }
            openForm(for: providers[selectedRow])
        case "a":
            openForm(for: nil)
        case "d":
            guard selectedRow < providers.count else { return }
            let id = providers[selectedRow].id
            try? await SettingsStore.shared.deleteProvider(id: id)
            await loadSettings()
            if selectedRow >= providers.count { selectedRow = max(0, providers.count - 1) }
            statusMessage = "Provider '\(id)' deleted."
        case "m":
            guard selectedRow < providers.count else { return }
            let pid = providers[selectedRow].id
            let models = cachedModels.filter { $0.providerID == pid }
            if models.isEmpty {
                statusMessage = "No models fetched for '\(pid)'. Press [r] to refresh first."
            } else {
                pickerProviderID = pid
                pickerSelectedRow = models.firstIndex { $0.key == globalDefault } ?? 0
                screen = .modelPicker
            }
        case "r":
            statusMessage = "Fetching models..."
            render()
            await refreshModels()
        default: break
        }
    }

    // MARK: - Form Screen

    private func handleFormKey(_ key: String) async {
        if formEditingField != nil {
            await handleFormEditKey(key)
            return
        }
        switch key {
        case "q", "\u{1B}":
            screen = .main
            statusMessage = ""
        case "j", "\u{1B}[B":
            var nextField = formSelectedField + 1
            if nextField == 4 && form.providerType != "mlx" { nextField += 1 }
            if nextField < formFieldCount { formSelectedField = nextField }
        case "k", "\u{1B}[A":
            var prevField = formSelectedField - 1
            if prevField == 4 && form.providerType != "mlx" { prevField -= 1 }
            if prevField >= 0 { formSelectedField = prevField }
        case "\r", "\n":
            await handleFormEnter()
        default: break
        }
    }

    private func handleFormEditKey(_ key: String) async {
        switch key {
        case "\r", "\n":
            let idx = formEditingField!
            applyEditBuffer(to: idx)
            formEditingField = nil
            formEditBuffer = ""
            formError = ""
        case "\u{1B}":
            formEditingField = nil
            formEditBuffer = ""
        case _ where key.hasPrefix("\u{1B}["):
            break
        default:
            for ch in key.unicodeScalars {
                if ch.value == 127 {
                    if !formEditBuffer.isEmpty { formEditBuffer.removeLast() }
                } else if ch.value >= 32 && ch.value <= 126 {
                    formEditBuffer.append(Character(ch))
                }
            }
        }
    }

    private func handleFormEnter() async {
        formError = ""
        switch formSelectedField {
        case 0:
            if form.isNew {
                formEditingField = 0
                formEditBuffer = form.id
            }
        case 1:
            form.cycleType()
            if formSelectedField == 4 && form.providerType != "mlx" {
                formSelectedField = 5
            }
        case 2:
            formEditingField = 2
            formEditBuffer = form.url
        case 3:
            formEditingField = 3
            formEditBuffer = form.apiKey
        case 4:
            if form.providerType == "mlx" {
                formEditingField = 4
                formEditBuffer = form.hfRepo
            }
        case 5:
            formEditingField = 5
            formEditBuffer = form.contextWindowOverride
        case 6:
            formEditingField = 6
            formEditBuffer = form.requestTimeout
        case 7:
            form.useStreaming = !form.useStreaming
        case 8:
            form.enabled = !form.enabled
        case 9:
            await saveForm()
        case 10:
            screen = .main
        default: break
        }
    }

    private func applyEditBuffer(to fieldRow: Int) {
        switch fieldRow {
        case 0:
            if form.isNew { form.id = formEditBuffer }
        case 2:
            form.url = formEditBuffer
        case 3:
            form.apiKey = formEditBuffer
        case 4:
            form.hfRepo = formEditBuffer
        case 5:
            form.contextWindowOverride = formEditBuffer
        case 6:
            form.requestTimeout = formEditBuffer
        default: break
        }
    }

    private func saveForm() async {
        if !form.contextWindowOverride.trimmingCharacters(in: .whitespaces).isEmpty,
           Int(form.contextWindowOverride.trimmingCharacters(in: .whitespaces)) == nil {
            formError = "Ctx Window must be a number or empty."
            return
        }
        if !form.requestTimeout.trimmingCharacters(in: .whitespaces).isEmpty,
           Double(form.requestTimeout.trimmingCharacters(in: .whitespaces)) == nil {
            formError = "Timeout must be a number (seconds) or empty."
            return
        }
        guard let config = form.toConfig() else {
            formError = "Provider ID is required."
            return
        }

        statusMessage = "Saving and fetching models..."
        render()
        let fetched = await fetchModels(from: config)
        if !fetched.isEmpty {
            await ModelCacheStandalone.shared.merge(fetched)
            cachedModels = await ModelCacheStandalone.shared.allModels()
        }

        try? await SettingsStore.shared.upsertProvider(config)
        await loadSettings()
        screen = .main
        selectedRow = providers.firstIndex(where: { $0.id == config.id }) ?? 0
        let modelCount = fetched.count
        if modelCount > 0 {
            statusMessage = "\(form.isNew ? "Added" : "Updated") '\(config.id)' — \(modelCount) model\(modelCount == 1 ? "" : "s") found."
        } else {
            statusMessage = "\(form.isNew ? "Added" : "Updated") '\(config.id)'. No models fetched (check URL)."
        }
    }

    private func openForm(for provider: ProviderConfig?) {
        if let p = provider {
            form = ProviderForm.from(p)
            formSelectedField = 1 // Start at type selection for editing
        } else {
            form = ProviderForm()
            formSelectedField = 0 // Start at ID selection for new
        }
        formEditingField = nil
        formEditBuffer = ""
        formError = ""
        screen = .form
    }

    // MARK: - Model Picker

    private func handlePickerKey(_ key: String) async {
        let models = cachedModels.filter { $0.providerID == pickerProviderID }
        switch key {
        case "q", "\u{1B}":
            screen = .main
            selectedRow = providers.firstIndex(where: { $0.id == pickerProviderID }) ?? 0
        case "j", "\u{1B}[B":
            if pickerSelectedRow < models.count - 1 { pickerSelectedRow += 1 }
        case "k", "\u{1B}[A":
            if pickerSelectedRow > 0 { pickerSelectedRow -= 1 }
        case "\r", "\n":
            guard pickerSelectedRow < models.count else { return }
            let selected = models[pickerSelectedRow]
            globalDefault = selected.key
            try? await SettingsStore.shared.setGlobalDefault(globalDefault)
            statusMessage = "Default model set to '\(globalDefault)'"
            screen = .main
            selectedRow = providers.firstIndex(where: { $0.id == pickerProviderID }) ?? 0
        default: break
        }
    }

    // MARK: - Rendering

    private func render() {
        clearScreen()
        moveTo(0, 0)
        switch screen {
        case .main:        renderMain()
        case .form:        renderForm()
        case .modelPicker: renderModelPicker()
        }
        if !statusMessage.isEmpty {
            let rows = terminalSize().rows
            moveTo(rows - 2, 0)
            print("\u{1B}[33m\(statusMessage)\u{1B}[0m", terminator: "")
        }
        fflush(stdout)
    }

    private func renderMain() {
        print("\u{1B}[1mPecan Configuration Manager\u{1B}[0m\n")
        print("Providers  \u{1B}[2m[a]dd  [d]elete  [r]efresh models  [m]odel picker  [q]uit\u{1B}[0m\n")

        if providers.isEmpty {
            print("  \u{1B}[2m(no providers configured — press [a] to add one)\u{1B}[0m\n")
        } else {
            for (i, p) in providers.enumerated() {
                let cursor = i == selectedRow ? "▶ " : "  "
                let status = p.enabled ? "\u{1B}[32m✓\u{1B}[0m" : "\u{1B}[31m✗\u{1B}[0m"
                let modelCount = cachedModels.filter { $0.providerID == p.id }.count
                let loadedCount = cachedModels.filter { $0.providerID == p.id && $0.isLoaded == true }.count
                let modelsStr: String
                if modelCount == 0 {
                    modelsStr = "\u{1B}[2m(not fetched)\u{1B}[0m"
                } else if loadedCount > 0 && loadedCount < modelCount {
                    modelsStr = "\u{1B}[2m(\(loadedCount) loaded / \(modelCount) total)\u{1B}[0m"
                } else {
                    modelsStr = "\u{1B}[2m(\(modelCount) model\(modelCount == 1 ? "" : "s"))\u{1B}[0m"
                }
                let url = p.url.map { "  \u{1B}[2m\($0)\u{1B}[0m" } ?? ""
                let detailStr = p.type == "mlx" ? "  \u{1B}[36mhf: \(p.huggingfaceRepo ?? "")\u{1B}[0m" : url
                print("\(cursor)\(status) \u{1B}[1m\(p.id)\u{1B}[0m  [\(p.type)]\(detailStr)  \(modelsStr)")
            }
        }

        let defaultDisplay = globalDefault.isEmpty
            ? "\u{1B}[2m(none)\u{1B}[0m"
            : "\u{1B}[33m\(globalDefault)\u{1B}[0m"
        print("\nGlobal default model: \(defaultDisplay)")

        print("\n\u{1B}[2mEnter to edit, [a] add, [d] delete, [m] pick default model, [r] refresh\u{1B}[0m")
    }

    private func renderForm() {
        let title = form.isNew ? "Add Provider" : "Edit Provider"
        print("\u{1B}[1m\(title)\u{1B}[0m\n")

        let labelWidth = 14

        for i in 0..<formFieldLabels.count {
            if i == 4 && form.providerType != "mlx" { continue }

            let isSelected = i == formSelectedField
            let isEditing = formEditingField == i
            let cursor = isSelected ? "▶ " : "  "
            let label = formFieldLabels[i].padding(toLength: labelWidth, withPad: " ", startingAt: 0)

            if i == 9 || i == 10 {
                let display = isSelected ? "\u{1B}[7m \(formFieldLabels[i]) \u{1B}[0m" : "[\(formFieldLabels[i])]"
                print("\(cursor)\(display)")
                continue
            }

            if i == 0 && !form.isNew {
                print("\(cursor)\(label) \(form.id)  \u{1B}[2m(read-only)\u{1B}[0m")
                continue
            }

            var rawValue = ""
            switch i {
            case 0: rawValue = form.id
            case 1: rawValue = form.providerType
            case 2: rawValue = form.url
            case 3: rawValue = form.apiKey.isEmpty ? "" : String(repeating: "•", count: min(form.apiKey.count, 24))
            case 4: rawValue = form.hfRepo
            case 5: rawValue = form.contextWindowOverride
            case 6: rawValue = form.requestTimeout.isEmpty ? "(default)" : form.requestTimeout + "s"
            case 7: rawValue = form.useStreaming ? "yes" : "no"
            case 8: rawValue = form.enabled ? "yes" : "no"
            default: break
            }

            let isCycleOrToggle = (i == 1 || i == 7 || i == 8)

            let valueDisplay: String
            if isEditing {
                valueDisplay = "\u{1B}[4m\(formEditBuffer)\u{1B}[0m█"
            } else if isCycleOrToggle {
                let action = i == 1 ? "cycle" : "toggle"
                let hint = isSelected ? "  \u{1B}[2m(Enter to \(action))\u{1B}[0m" : ""
                valueDisplay = "\u{1B}[36m\(rawValue)\u{1B}[0m\(hint)"
            } else if rawValue.isEmpty {
                let hint = isSelected ? "  \u{1B}[2m(Enter to edit)\u{1B}[0m" : ""
                valueDisplay = "\u{1B}[2m(empty)\u{1B}[0m\(hint)"
            } else {
                let hint = isSelected ? "  \u{1B}[2m(Enter to edit)\u{1B}[0m" : ""
                valueDisplay = "\(rawValue)\(hint)"
            }

            if isSelected {
                print("\(cursor)\u{1B}[1m\(label)\u{1B}[0m \(valueDisplay)")
            } else {
                print("\(cursor)\(label) \(valueDisplay)")
            }
        }

        if !formError.isEmpty {
            print("\n\u{1B}[31m⚠ \(formError)\u{1B}[0m")
        }

        print("\n\u{1B}[2mj/k ↑↓ navigate · Enter edit/toggle/save · Esc cancel edit · q back\u{1B}[0m")
    }

    private func renderModelPicker() {
        let models = cachedModels.filter { $0.providerID == pickerProviderID }
        print("\u{1B}[1mSelect default model — \(pickerProviderID)\u{1B}[0m\n")

        if models.isEmpty {
            print("  \u{1B}[2mNo models available. Go back and press [r] to refresh.\u{1B}[0m\n")
        } else {
            let maxIDLen = models.map { $0.modelID.count }.max() ?? 0

            for (i, m) in models.enumerated() {
                let isSelected = i == pickerSelectedRow
                let isCurrent = m.key == globalDefault
                let cursor = isSelected ? "▶ " : "  "

                let loadedBadge: String
                switch m.isLoaded {
                case true:  loadedBadge = "\u{1B}[32m● loaded  \u{1B}[0m"
                case false: loadedBadge = "\u{1B}[31m○ unloaded\u{1B}[0m"
                default:    loadedBadge = "\u{1B}[2m          \u{1B}[0m"
                }

                let ctxStr: String
                if let ctx = m.contextWindow {
                    let ctxK = ctx >= 1024 ? "\(ctx / 1024)k" : "\(ctx)"
                    ctxStr = "\(ctxK) ctx"
                } else {
                    ctxStr = ""
                }

                let sizeInfo = [m.formattedParams, m.formattedSize].compactMap { $0 }.joined(separator: "  ")
                let idPadded = m.modelID.padding(toLength: maxIDLen + 2, withPad: " ", startingAt: 0)
                let ctxPadded = ctxStr.padding(toLength: 22, withPad: " ", startingAt: 0)
                let currentMark = isCurrent ? "  \u{1B}[32m✓ current\u{1B}[0m" : ""

                if isSelected {
                    print("\(cursor)\u{1B}[1m\(idPadded)\u{1B}[0m  \(loadedBadge)  \u{1B}[2m\(ctxPadded)\u{1B}[0m  \(sizeInfo)\(currentMark)")
                } else {
                    print("\(cursor)\u{1B}[2m\(idPadded)\u{1B}[0m  \(loadedBadge)  \u{1B}[2m\(ctxPadded)  \(sizeInfo)\u{1B}[0m\(currentMark)")
                }
            }
        }

        print("\n\u{1B}[2mj/k ↑↓ navigate · Enter to set as default · q/Esc back\u{1B}[0m")
    }

    // MARK: - Data Helpers

    private func refreshModels() async {
        await ModelCacheStandalone.shared.refresh(providers: providers)
        cachedModels = await ModelCacheStandalone.shared.allModels()
        let count = cachedModels.count
        statusMessage = "Fetched \(count) model\(count == 1 ? "" : "s")."
    }

    private func loadSettings() async {
        providers = (try? await SettingsStore.shared.allProviders()) ?? []
        globalDefault = (try? await SettingsStore.shared.globalDefault()) ?? ""
        personaModels = (try? await SettingsStore.shared.allPersonaModels()) ?? []
    }

    // MARK: - Terminal Helpers

    private func terminalSize() -> (rows: Int, cols: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 { return (Int(ws.ws_row), Int(ws.ws_col)) }
        return (24, 80)
    }

    private func moveTo(_ row: Int, _ col: Int) {
        print("\u{1B}[\(row + 1);\(col + 1)H", terminator: "")
    }

    private func clearScreen() { print("\u{1B}[2J\u{1B}[H", terminator: "") }
    private func hideCursor() { print("\u{1B}[?25l", terminator: "") }
    private func showCursor() { print("\u{1B}[?25h", terminator: "") }

    private func readKey() -> String? {
        var buf = [UInt8](repeating: 0, count: 8)
        let n = read(STDIN_FILENO, &buf, 8)
        guard n > 0 else { return nil }
        return String(bytes: buf.prefix(n), encoding: .utf8)
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
