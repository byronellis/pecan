import Foundation
import ANSITerminal
import PecanSettings

// MARK: - Interactive configuration TUI

func runConfigureTUI() async {
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
    // Add mode: URL → API Key → auto-suggested ID
    // Edit mode: all fields, ID shown as read-only header

    var originalID: String?  // nil = new provider
    var id: String = ""
    var providerType: String = "openai"
    var url: String = ""
    var apiKey: String = ""
    var hfRepo: String = ""
    var contextWindowOverride: String = ""
    var enabled: Bool = true

    var isNew: Bool { originalID == nil }
    static let types = ["openai", "mlx", "mock"]

    mutating func cycleType() {
        let idx = Self.types.firstIndex(of: providerType) ?? 0
        providerType = Self.types[(idx + 1) % Self.types.count]
    }

    // Suggest an ID from a URL (uses the hostname)
    mutating func suggestIDFromURL() {
        guard id.isEmpty, !url.isEmpty,
              let host = URL(string: url.trimmingCharacters(in: .whitespaces))?.host,
              !host.isEmpty else { return }
        // Strip common prefixes to keep IDs concise: "192.168.1.x" → keep, "api.openai.com" → "openai"
        let parts = host.split(separator: ".").map(String.init)
        if parts.count >= 2 && parts.last == "com" || parts.last == "io" || parts.last == "ai" {
            id = parts.dropLast().last ?? host
        } else {
            id = host
        }
    }

    func toConfig() -> ProviderConfig? {
        let trimID = id.trimmingCharacters(in: .whitespaces)
        guard !trimID.isEmpty else { return nil }
        let trimURL = url.trimmingCharacters(in: .whitespaces)
        let trimKey = apiKey.trimmingCharacters(in: .whitespaces)
        let trimRepo = hfRepo.trimmingCharacters(in: .whitespaces)
        let trimCtx = contextWindowOverride.trimmingCharacters(in: .whitespaces)
        return ProviderConfig(
            id: trimID,
            type: providerType,
            url: trimURL.isEmpty ? nil : trimURL,
            apiKey: trimKey.isEmpty ? nil : trimKey,
            huggingfaceRepo: trimRepo.isEmpty ? nil : trimRepo,
            contextWindowOverride: Int(trimCtx),
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
            enabled: p.enabled
        )
    }
}

// MARK: - ConfigureTUI

@MainActor
final class ConfigureTUI {

    // Main screen
    private var providers: [ProviderConfig] = []
    private var cachedModels: [RemoteModelInfo] = []
    private var personaModels: [(persona: String, modelKey: String)] = []
    private var globalDefault: String = ""
    private var selectedRow: Int = 0

    // Screen routing
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

    // MARK: - Field layout constants

    // Add mode field indices: 0=URL, 1=API Key, 2=Provider ID, 3=Save, 4=Cancel
    private let addFieldLabels = ["URL", "API Key", "Provider ID", "Save", "Cancel"]
    private let addFieldCount = 5

    // Edit mode field indices: 0=Type, 1=URL, 2=API Key, 3=HF Repo, 4=Ctx Window, 5=Enabled, 6=Save, 7=Cancel
    private let editFieldLabels = ["Type", "URL", "API Key", "HF Repo", "Ctx Window", "Enabled", "Save", "Cancel"]
    private let editFieldCount = 8

    private var currentFieldCount: Int { form.isNew ? addFieldCount : editFieldCount }

    // MARK: - Run loop

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

    // MARK: - Main screen

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

    // MARK: - Form screen

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
            if formSelectedField < currentFieldCount - 1 { formSelectedField += 1 }

        case "k", "\u{1B}[A":
            if formSelectedField > 0 { formSelectedField -= 1 }

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
            break  // arrow sequences — ignore in edit mode

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
        if form.isNew {
            switch formSelectedField {
            case 0:  // URL
                formEditingField = 0; formEditBuffer = form.url
            case 1:  // API Key
                formEditingField = 1; formEditBuffer = form.apiKey
            case 2:  // Provider ID
                formEditingField = 2; formEditBuffer = form.id
            case 3:  // Save
                await saveForm()
            case 4:  // Cancel
                screen = .main
            default: break
            }
        } else {
            switch formSelectedField {
            case 0:  // Type
                form.cycleType()
            case 1:  // URL
                formEditingField = 1; formEditBuffer = form.url
            case 2:  // API Key
                formEditingField = 2; formEditBuffer = form.apiKey
            case 3:  // HF Repo
                formEditingField = 3; formEditBuffer = form.hfRepo
            case 4:  // Ctx Window
                formEditingField = 4; formEditBuffer = form.contextWindowOverride
            case 5:  // Enabled
                form.enabled = !form.enabled
            case 6:  // Save
                await saveForm()
            case 7:  // Cancel
                screen = .main
            default: break
            }
        }
    }

    private func applyEditBuffer(to fieldRow: Int) {
        if form.isNew {
            switch fieldRow {
            case 0:
                form.url = formEditBuffer
                form.suggestIDFromURL()  // auto-populate ID from hostname if ID is still empty
            case 1:
                form.apiKey = formEditBuffer
            case 2:
                form.id = formEditBuffer
            default: break
            }
        } else {
            switch fieldRow {
            case 1: form.url = formEditBuffer
            case 2: form.apiKey = formEditBuffer
            case 3: form.hfRepo = formEditBuffer
            case 4: form.contextWindowOverride = formEditBuffer
            default: break
            }
        }
    }

    private func saveForm() async {
        if !form.contextWindowOverride.trimmingCharacters(in: .whitespaces).isEmpty,
           Int(form.contextWindowOverride.trimmingCharacters(in: .whitespaces)) == nil {
            formError = "Ctx Window must be a number or empty."
            return
        }
        guard let config = form.toConfig() else {
            formError = "Provider ID is required."
            return
        }

        // Fetch models before saving so we populate the cache immediately
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
            formSelectedField = 0
        } else {
            form = ProviderForm()
            formSelectedField = 0
        }
        formEditingField = nil
        formEditBuffer = ""
        formError = ""
        screen = .form
    }

    // MARK: - Model picker screen

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
        print("\u{1B}[1mPecan Configuration\u{1B}[0m\n")
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
                print("\(cursor)\(status) \u{1B}[1m\(p.id)\u{1B}[0m  [\(p.type)]\(url)  \(modelsStr)")
            }
        }

        let defaultDisplay = globalDefault.isEmpty
            ? "\u{1B}[2m(none)\u{1B}[0m"
            : "\u{1B}[33m\(globalDefault)\u{1B}[0m"
        print("\nGlobal default model: \(defaultDisplay)")

        if !personaModels.isEmpty {
            print("\nPersona model assignments:")
            for (persona, modelKey) in personaModels {
                print("  \u{1B}[2m\(persona)\u{1B}[0m → \(modelKey)")
            }
        }

        print("\n\u{1B}[2mEnter to edit, [a] add, [d] delete, [m] pick default model, [r] refresh\u{1B}[0m")
    }

    private func renderForm() {
        let title = form.isNew ? "Add Provider" : "Edit Provider"
        print("\u{1B}[1m\(title)\u{1B}[0m\n")

        if !form.isNew {
            print("  \u{1B}[2mID:  \(form.id)\u{1B}[0m\n")
        }

        let labels = form.isNew ? addFieldLabels : editFieldLabels
        let labelWidth = 14

        for i in 0..<labels.count {
            let isSelected = i == formSelectedField
            let isEditing = formEditingField == i
            let cursor = isSelected ? "▶ " : "  "
            let label = labels[i].padding(toLength: labelWidth, withPad: " ", startingAt: 0)

            // Button rows
            if (form.isNew && (i == 3 || i == 4)) || (!form.isNew && (i == 6 || i == 7)) {
                let display = isSelected ? "\u{1B}[7m \(labels[i]) \u{1B}[0m" : "[\(labels[i])]"
                print("\(cursor)\(display)")
                continue
            }

            // Compute display value
            let rawValue: String
            if form.isNew {
                switch i {
                case 0: rawValue = form.url
                case 1: rawValue = form.apiKey.isEmpty ? "" : String(repeating: "•", count: min(form.apiKey.count, 24))
                case 2: rawValue = form.id
                default: rawValue = ""
                }
            } else {
                switch i {
                case 0: rawValue = form.providerType
                case 1: rawValue = form.url
                case 2: rawValue = form.apiKey.isEmpty ? "" : String(repeating: "•", count: min(form.apiKey.count, 24))
                case 3: rawValue = form.hfRepo
                case 4: rawValue = form.contextWindowOverride
                case 5: rawValue = form.enabled ? "yes" : "no"
                default: rawValue = ""
                }
            }

            let isCycleOrToggle = !form.isNew && (i == 0 || i == 5)

            let valueDisplay: String
            if isEditing {
                let displayBuf = (form.isNew && i == 1) || (!form.isNew && i == 2) ? formEditBuffer : formEditBuffer
                _ = displayBuf
                valueDisplay = "\u{1B}[4m\(formEditBuffer)\u{1B}[0m█"
            } else if isCycleOrToggle {
                let action = i == 0 ? "cycle" : "toggle"
                let hint = isSelected ? "  \u{1B}[2m(Enter to \(action))\u{1B}[0m" : ""
                valueDisplay = "\u{1B}[36m\(rawValue)\u{1B}[0m\(hint)"
            } else if rawValue.isEmpty {
                let hint: String
                if isSelected {
                    hint = i == 1 && form.isNew ? "  \u{1B}[2m(optional, Enter to skip)\u{1B}[0m"
                                                : "  \u{1B}[2m(Enter to edit)\u{1B}[0m"
                } else { hint = "" }
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

        if form.isNew {
            print("\u{1B}[2mModels will be fetched automatically when you Save.\u{1B}[0m")
        }
    }

    private func renderModelPicker() {
        let models = cachedModels.filter { $0.providerID == pickerProviderID }
        print("\u{1B}[1mSelect default model — \(pickerProviderID)\u{1B}[0m\n")

        if models.isEmpty {
            print("  \u{1B}[2mNo models available. Go back and press [r] to refresh.\u{1B}[0m\n")
        } else {
            // Pre-compute display widths for alignment
            let maxIDLen = models.map { $0.modelID.count }.max() ?? 0

            for (i, m) in models.enumerated() {
                let isSelected = i == pickerSelectedRow
                let isCurrent = m.key == globalDefault
                let cursor = isSelected ? "▶ " : "  "

                // Loaded indicator
                let loadedBadge: String
                switch m.isLoaded {
                case true:  loadedBadge = "\u{1B}[32m● loaded  \u{1B}[0m"
                case false: loadedBadge = "\u{1B}[31m○ unloaded\u{1B}[0m"
                default:    loadedBadge = "\u{1B}[2m          \u{1B}[0m"
                }

                // Context info
                let ctxStr: String
                if let ctx = m.contextWindow {
                    let ctxK = ctx >= 1024 ? "\(ctx / 1024)k" : "\(ctx)"
                    if let train = m.contextWindowTrain, train != ctx {
                        ctxK == "\(train / 1024)k"
                            ? (ctxStr = "\(ctxK) ctx")
                            : (ctxStr = "\(ctxK) ctx / \(train / 1024)k train")
                    } else {
                        ctxStr = "\(ctxK) ctx"
                    }
                } else if let train = m.contextWindowTrain {
                    ctxStr = "—  / \(train / 1024)k train"
                } else {
                    ctxStr = ""
                }

                // Params + size
                let sizeInfo = [m.formattedParams, m.formattedSize].compactMap { $0 }.joined(separator: "  ")

                // Pad model ID for alignment
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

    // MARK: - Data helpers

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

    // MARK: - Terminal helpers

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

// MARK: - Standalone model cache (no gRPC server needed)

actor ModelCacheStandalone {
    static let shared = ModelCacheStandalone()
    private var models: [RemoteModelInfo] = []
    private init() {}

    func refresh(providers: [ProviderConfig]) async {
        var result: [RemoteModelInfo] = []
        for p in providers where p.enabled {
            result.append(contentsOf: await fetchModels(from: p))
        }
        if !result.isEmpty { models = result }
    }

    /// Merge newly fetched models for a single provider into the cache.
    func merge(_ newModels: [RemoteModelInfo]) {
        guard let providerID = newModels.first?.providerID else { return }
        models.removeAll { $0.providerID == providerID }
        models.append(contentsOf: newModels)
    }

    func allModels() -> [RemoteModelInfo] { models }
}

private func fetchModels(from provider: ProviderConfig) async -> [RemoteModelInfo] {
    switch provider.type.lowercased() {
    case "openai":
        return await fetchOpenAIModels(provider: provider)
    case "mlx":
        return [RemoteModelInfo(providerID: provider.id, modelID: provider.id,
                                contextWindow: provider.contextWindowOverride, isLoaded: true)]
    case "mock":
        return [RemoteModelInfo(providerID: provider.id, modelID: "mock",
                                contextWindow: 8192, contextWindowTrain: 8192, isLoaded: true)]
    default:
        return []
    }
}

private func fetchOpenAIModels(provider: ProviderConfig) async -> [RemoteModelInfo] {
    guard provider.type.lowercased() == "openai",
          let baseURL = provider.url, !baseURL.isEmpty else {
        return [RemoteModelInfo(providerID: provider.id, modelID: provider.id)]
    }
    let urlStr = baseURL.hasSuffix("/") ? baseURL + "v1/models" : baseURL + "/v1/models"
    guard let url = URL(string: urlStr) else { return [] }
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = "GET"
    if let key = provider.apiKey, !key.isEmpty, key.lowercased() != "none" {
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    do {
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else { return [] }
        return dataArray.compactMap { entry -> RemoteModelInfo? in
            guard let id = entry["id"] as? String else { return nil }
            let meta = entry["meta"] as? [String: Any]
            let nCtx = meta?["n_ctx"] as? Int
            let nCtxTrain = meta?["n_ctx_train"] as? Int
            let ctx = nCtx ?? nCtxTrain ?? provider.contextWindowOverride

            let isLoaded: Bool?
            if let loaded = entry["loaded"] as? Bool { isLoaded = loaded }
            else if let status = entry["status"] as? String { isLoaded = status == "loaded" }
            else if nCtx != nil { isLoaded = true }
            else { isLoaded = nil }

            let paramCount: Int?
            if let p = meta?["n_params"] as? Int { paramCount = p }
            else if let p = meta?["n_params"] as? Double { paramCount = Int(p) }
            else { paramCount = nil }

            let sizeBytes: Int?
            if let s = meta?["size"] as? Int { sizeBytes = s }
            else if let s = meta?["size"] as? Double { sizeBytes = Int(s) }
            else { sizeBytes = nil }

            return RemoteModelInfo(providerID: provider.id, modelID: id,
                                   contextWindow: ctx, contextWindowTrain: nCtxTrain,
                                   isLoaded: isLoaded, paramCount: paramCount, sizeBytes: sizeBytes)
        }
    } catch { return [] }
}
