import Foundation
import ANSITerminal
import PecanSettings

// MARK: - Interactive configuration TUI

/// Runs the interactive `pecan configure` mode.
/// Operates directly on SettingsStore — does not need the server.
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

@MainActor
final class ConfigureTUI {
    private var providers: [ProviderConfig] = []
    private var cachedModels: [RemoteModelInfo] = []
    private var personaModels: [(persona: String, modelKey: String)] = []
    private var globalDefault: String = ""
    private var selectedRow: Int = 0
    private var screen: Screen = .main
    private var statusMessage: String = ""

    enum Screen {
        case main
        case addProvider
        case editProvider(Int)
        case modelPicker(forProvider: Int)
    }

    func run() async {
        await loadSettings()

        enableRawMode()
        hideCursor()
        clearScreen()
        defer {
            showCursor()
            disableRawMode()
            clearScreen()
        }

        render()

        while true {
            guard let key = readKey() else { continue }

            switch key {
            case "q", "\u{1B}":  // q or Escape
                if case .main = screen {
                    return
                }
                screen = .main
                selectedRow = 0
                render()

            case "j", "\u{1B}[B":  // j or Down arrow
                moveDown()
                render()

            case "k", "\u{1B}[A":  // k or Up arrow
                moveUp()
                render()

            case "\r", "\n":  // Enter
                await handleEnter()
                render()

            case "a":
                if case .main = screen {
                    screen = .addProvider
                    render()
                }

            case "d":
                if case .main = screen {
                    await deleteSelectedProvider()
                    render()
                }

            case "r":
                if case .main = screen {
                    await refreshModels()
                    render()
                }

            case "s":
                if case .main = screen {
                    try? await SettingsStore.shared.setGlobalDefault(globalDefault)
                    statusMessage = "Settings saved."
                    render()
                }

            default:
                if case .addProvider = screen {
                    await handleAddProviderInput(key)
                } else if case .editProvider(let idx) = screen {
                    await handleEditProviderInput(key, index: idx)
                }
            }
        }
    }

    // MARK: - Rendering

    private func render() {
        clearScreen()
        moveTo(0, 0)

        switch screen {
        case .main:
            renderMain()
        case .addProvider:
            renderAddProvider()
        case .editProvider(let idx):
            renderEditProvider(idx)
        case .modelPicker(let idx):
            renderModelPicker(idx)
        }

        if !statusMessage.isEmpty {
            let rows = terminalSize().rows
            moveTo(rows - 1, 0)
            print("\u{1B}[33m\(statusMessage)\u{1B}[0m", terminator: "")
        }
        fflush(stdout)
    }

    private func renderMain() {
        print("\u{1B}[1mPecan Configuration\u{1B}[0m\n")
        print("Providers  [a]dd  [d]elete  [r]efresh models  [s]save  [q]uit\n")

        if providers.isEmpty {
            print("  (no providers configured)\n")
        } else {
            for (i, p) in providers.enumerated() {
                let cursor = i == selectedRow ? "▶ " : "  "
                let status = p.enabled ? "\u{1B}[32m✓\u{1B}[0m" : "\u{1B}[31m✗\u{1B}[0m"
                let modelCount = cachedModels.filter { $0.providerID == p.id }.count
                let models = modelCount > 0 ? "(\(modelCount) models)" : "(not fetched)"
                let url = p.url ?? ""
                print("\(cursor)\(status) \u{1B}[1m\(p.id)\u{1B}[0m  [\(p.type)]  \(url)  \(models)")
            }
        }

        print("\nGlobal default model: \u{1B}[33m\(globalDefault.isEmpty ? "(none)" : globalDefault)\u{1B}[0m")

        if !personaModels.isEmpty {
            print("\nPersona model assignments:")
            for (persona, modelKey) in personaModels {
                print("  \(persona) → \(modelKey)")
            }
        }

        print("\nPress Enter to edit selected provider, [a] to add new.")
    }

    private func renderAddProvider() {
        print("\u{1B}[1mAdd Provider\u{1B}[0m\n")
        print("Enter provider details below. Press Ctrl+C to cancel.\n")
        print("This is an interactive form. For now, edit settings directly:")
        print("  ~/.pecan/settings.db\n")
        print("Or use /settings commands within a pecan session.\n")
        print("(Full interactive form coming in next iteration)\n")
        print("[q] Back")
    }

    private func renderEditProvider(_ idx: Int) {
        guard idx < providers.count else { screen = .main; return }
        let p = providers[idx]
        print("\u{1B}[1mEdit Provider: \(p.id)\u{1B}[0m\n")
        print("  ID:       \(p.id)")
        print("  Type:     \(p.type)")
        print("  URL:      \(p.url ?? "(none)")")
        print("  API Key:  \(p.apiKey.map { _ in "***" } ?? "(none)")")
        print("  HF Repo:  \(p.huggingfaceRepo ?? "(none)")")
        print("  Enabled:  \(p.enabled ? "yes" : "no")")

        let models = cachedModels.filter { $0.providerID == p.id }
        if models.isEmpty {
            print("\n  No models fetched yet. Press [r] to fetch.")
        } else {
            print("\n  Models (\(models.count)):")
            for m in models.prefix(8) {
                let ctx = m.contextWindow.map { "  \($0/1024)k ctx" } ?? ""
                print("    \(m.modelID)\(ctx)")
            }
            if models.count > 8 { print("    ... and \(models.count - 8) more") }
        }

        print("\n[r] Refresh models  [t] Toggle enabled  [q] Back")
    }

    private func renderModelPicker(_ idx: Int) {
        guard idx < providers.count else { screen = .main; return }
        let providerID = providers[idx].id
        let models = cachedModels.filter { $0.providerID == providerID }
        print("\u{1B}[1mSelect default model for \(providerID)\u{1B}[0m\n")
        for (i, m) in models.enumerated() {
            let cursor = i == selectedRow ? "▶ " : "  "
            let ctx = m.contextWindow.map { "  (\($0/1024)k ctx)" } ?? ""
            print("\(cursor)\(m.modelID)\(ctx)")
        }
        print("\n[Enter] Select  [q] Back")
    }

    // MARK: - Input handling

    private func moveDown() {
        switch screen {
        case .main:
            if selectedRow < providers.count - 1 { selectedRow += 1 }
        case .modelPicker(let idx):
            let count = cachedModels.filter { $0.providerID == providers[idx].id }.count
            if selectedRow < count - 1 { selectedRow += 1 }
        default: break
        }
    }

    private func moveUp() {
        if selectedRow > 0 { selectedRow -= 1 }
    }

    private func handleEnter() async {
        switch screen {
        case .main:
            guard !providers.isEmpty else { return }
            screen = .editProvider(selectedRow)
            selectedRow = 0
        case .editProvider(let idx):
            screen = .modelPicker(forProvider: idx)
            selectedRow = 0
        case .modelPicker(let idx):
            guard idx < providers.count else { return }
            let providerID = providers[idx].id
            let models = cachedModels.filter { $0.providerID == providerID }
            guard selectedRow < models.count else { return }
            let selected = models[selectedRow]
            globalDefault = selected.key
            try? await SettingsStore.shared.setGlobalDefault(globalDefault)
            statusMessage = "Default model set to '\(globalDefault)'"
            screen = .main
            selectedRow = idx
        case .addProvider:
            break
        }
    }

    private func handleAddProviderInput(_ key: String) async {
        // Placeholder — full interactive form in next iteration
        screen = .main
    }

    private func handleEditProviderInput(_ key: String, index: Int) async {
        guard index < providers.count else { return }
        switch key {
        case "r":
            await refreshModels()
            statusMessage = "Models refreshed."
        case "t":
            let p = providers[index]
            let updated = ProviderConfig(
                id: p.id, type: p.type, url: p.url, apiKey: p.apiKey,
                huggingfaceRepo: p.huggingfaceRepo, contextWindowOverride: p.contextWindowOverride,
                enabled: !p.enabled
            )
            try? await SettingsStore.shared.upsertProvider(updated)
            await loadSettings()
            statusMessage = "Provider '\(p.id)' \(updated.enabled ? "enabled" : "disabled")."
        default: break
        }
    }

    private func deleteSelectedProvider() async {
        guard selectedRow < providers.count else { return }
        let id = providers[selectedRow].id
        try? await SettingsStore.shared.deleteProvider(id: id)
        await loadSettings()
        if selectedRow >= providers.count { selectedRow = max(0, providers.count - 1) }
        statusMessage = "Provider '\(id)' deleted."
    }

    private func refreshModels() async {
        statusMessage = "Fetching models..."
        render()
        await ModelCacheStandalone.shared.refresh(providers: providers)
        cachedModels = await ModelCacheStandalone.shared.allModels()
        statusMessage = "Fetched \(cachedModels.count) models."
    }

    private func loadSettings() async {
        providers = (try? await SettingsStore.shared.allProviders()) ?? []
        globalDefault = (try? await SettingsStore.shared.globalDefault()) ?? ""
        personaModels = (try? await SettingsStore.shared.allPersonaModels()) ?? []
    }

    // MARK: - Terminal helpers

    private func terminalSize() -> (rows: Int, cols: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
            return (Int(ws.ws_row), Int(ws.ws_col))
        }
        return (24, 80)
    }

    private func moveTo(_ row: Int, _ col: Int) {
        print("\u{1B}[\(row + 1);\(col + 1)H", terminator: "")
    }

    private func clearScreen() {
        print("\u{1B}[2J\u{1B}[H", terminator: "")
    }

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

// MARK: - Standalone model cache for configure mode (no GRPC server needed)

actor ModelCacheStandalone {
    static let shared = ModelCacheStandalone()
    private var models: [RemoteModelInfo] = []
    private init() {}

    func refresh(providers: [ProviderConfig]) async {
        var result: [RemoteModelInfo] = []
        for p in providers where p.enabled {
            let fetched = await fetchModels(from: p)
            result.append(contentsOf: fetched)
        }
        if !result.isEmpty { models = result }
    }

    func allModels() -> [RemoteModelInfo] { models }
}

private func fetchModels(from provider: ProviderConfig) async -> [RemoteModelInfo] {
    guard provider.type.lowercased() == "openai", let baseURL = provider.url, !baseURL.isEmpty else {
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
            let ctx: Int?
            if let meta = entry["meta"] as? [String: Any] {
                ctx = (meta["n_ctx"] as? Int) ?? (meta["n_ctx_train"] as? Int)
            } else { ctx = nil }
            return RemoteModelInfo(providerID: provider.id, modelID: id, contextWindow: ctx)
        }
    } catch { return [] }
}
