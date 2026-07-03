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
    private var inMemoryActiveModels: [String: [String]] = [:]     // provider_id -> active model IDs
    private var inMemoryAvailableModels: [String: [String]] = [:]  // provider_id -> all discovered/fetched model IDs
    
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
    private var formEditCursor: Int = 0       // cursor position (index into formEditBuffer)
    private var formKillRing: String = ""     // yank buffer (shared for both editors)
    private var formError: String = ""

    // Values of the provider currently being edited
    private var editID: String = ""
    private var editType: String = ""
    private var editURL: String = ""
    private var editKey: String = ""
    private var editHF: String = ""
    private var editEnabled: Bool = false
    private var editActiveModels: Set<String> = []

    // Custom model ID manual insertion state
    private var isAddingModelID = false
    private var newModelIDBuffer = ""
    private var newModelIDCursor: Int = 0

    // Directory Explorer state
    private var isShowingDirExplorer = false
    private var explorerPath: String = ""
    private var explorerLeftItems: [String] = []
    private var explorerLeftSelectedIndex: Int = 0
    private var explorerRightItems: [String] = []

    // Model Info Modal state
    private var isShowingModelModal = false
    private var modalModelID: String = ""
    private var modalModelCostIn: String = ""
    private var modalModelCostOut: String = ""
    private var modalModelCtx: String = ""

    // Loading indicator state
    private var isFetchingModels = false

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
        
        // 2. Add "Fireworks.AI"
        if let fireworks = existing.first(where: { $0.id == "fireworks" }) {
            inMemoryProviders.append(fireworks)
        } else {
            inMemoryProviders.append(ProviderConfig(id: "fireworks", type: "fireworks", url: "https://api.fireworks.ai/inference/v1", enabled: false))
        }
        
        // 3. Add "Huggingface"
        if let hf = existing.first(where: { $0.id == "huggingface" }) {
            inMemoryProviders.append(hf)
        } else {
            inMemoryProviders.append(ProviderConfig(id: "huggingface", type: "huggingface", url: "https://router.huggingface.co/v1", enabled: false))
        }
        
        // 4. Add custom OpenAI providers
        for p in existing {
            if p.id != "mlx" && p.id != "fireworks" && p.id != "huggingface" {
                inMemoryProviders.append(p)
            }
        }

        // Load active models from DB for each loaded provider
        for p in inMemoryProviders {
            let active = (try? await SettingsStore.shared.activeModels(providerID: p.id)) ?? []
            inMemoryActiveModels[p.id] = active
            
            if p.id == "mlx", let repo = p.huggingfaceRepo {
                inMemoryAvailableModels["mlx"] = scanMLXModels(dirPath: repo)
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
                
                if isShowingModelModal {
                    // Modal absorbs all keys to close
                    isShowingModelModal = false
                    handled = true
                } else if isShowingDirExplorer {
                    handled = handleExplorerKey(key)
                } else if splitLayout.activePane == .mainPanel {
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
            termRows = Int(ws.ws_row) - 1
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
            
            // Serialize active models list
            let active = inMemoryActiveModels[p.id] ?? []
            if !active.isEmpty {
                yaml += "    active_models:\n"
                for model in active {
                    yaml += "      - \(model)\n"
                }
            }
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
            
            // Sync active models in the transient DB
            let active = inMemoryActiveModels[p.id] ?? []
            try? await SettingsStore.shared.syncActiveModels(providerID: p.id, activeModels: active)
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

    // MARK: - Main Panel Key Handlers

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

    // MARK: - LineEditor helpers (operate on a (buffer, cursor) pair)

    private func leInsert(_ c: Character, buf: inout String, cur: inout Int) {
        guard c != "\n" && c != "\r" && c != "\t" else { return }
        let idx = buf.index(buf.startIndex, offsetBy: cur)
        buf.insert(c, at: idx)
        cur += 1
    }

    private func leBackspace(buf: inout String, cur: inout Int) {
        guard cur > 0 else { return }
        let end = buf.index(buf.startIndex, offsetBy: cur)
        let start = buf.index(before: end)
        buf.remove(at: start)
        cur -= 1
    }

    private func leDeleteForward(buf: inout String, cur: inout Int) {
        guard cur < buf.count else { return }
        let idx = buf.index(buf.startIndex, offsetBy: cur)
        buf.remove(at: idx)
    }

    private func leMoveLeft(buf: inout String, cur: inout Int) {
        if cur > 0 { cur -= 1 }
    }

    private func leMoveRight(buf: inout String, cur: inout Int) {
        if cur < buf.count { cur += 1 }
    }

    private func leMoveHome(buf: inout String, cur: inout Int) {
        cur = 0
    }

    private func leMoveEnd(buf: inout String, cur: inout Int) {
        cur = buf.count
    }

    /// Move backward one word (Alt+B / Alt+Left)
    private func leWordLeft(buf: inout String, cur: inout Int) {
        var i = cur
        // skip non-alphanum
        while i > 0 && !buf[buf.index(buf.startIndex, offsetBy: i - 1)].isLetter { i -= 1 }
        // skip alphanum
        while i > 0 && buf[buf.index(buf.startIndex, offsetBy: i - 1)].isLetter { i -= 1 }
        cur = i
    }

    /// Move forward one word (Alt+F / Alt+Right)
    private func leWordRight(buf: inout String, cur: inout Int) {
        var i = cur
        let count = buf.count
        while i < count && !buf[buf.index(buf.startIndex, offsetBy: i)].isLetter { i += 1 }
        while i < count && buf[buf.index(buf.startIndex, offsetBy: i)].isLetter { i += 1 }
        cur = i
    }

    /// Kill from cursor to end of line (^K)
    private func leKillToEnd(buf: inout String, cur: inout Int, ring: inout String) {
        let idx = buf.index(buf.startIndex, offsetBy: cur)
        ring = String(buf[idx...])
        buf = String(buf[..<idx])
    }

    /// Kill from start to cursor (^U)
    private func leKillToStart(buf: inout String, cur: inout Int, ring: inout String) {
        let idx = buf.index(buf.startIndex, offsetBy: cur)
        ring = String(buf[..<idx])
        buf = String(buf[idx...])
        cur = 0
    }

    /// Kill previous word (^W)
    private func leKillWordBackward(buf: inout String, cur: inout Int, ring: inout String) {
        var i = cur
        while i > 0 && buf[buf.index(buf.startIndex, offsetBy: i - 1)] == " " { i -= 1 }
        while i > 0 && buf[buf.index(buf.startIndex, offsetBy: i - 1)] != " " { i -= 1 }
        let start = buf.index(buf.startIndex, offsetBy: i)
        let end = buf.index(buf.startIndex, offsetBy: cur)
        ring = String(buf[start..<end])
        buf.removeSubrange(start..<end)
        cur = i
    }

    /// Yank from kill ring (^Y)
    private func leYank(buf: inout String, cur: inout Int, ring: String) {
        guard !ring.isEmpty else { return }
        let idx = buf.index(buf.startIndex, offsetBy: cur)
        buf.insert(contentsOf: ring, at: idx)
        cur += ring.count
    }

    // MARK: - handleFormKey
    private func handleFormKey(_ key: InputKey, isNew: Bool, index: Int?) async -> Bool {
        if isAddingModelID {
            switch key {
            case .enter:
                let mName = newModelIDBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !mName.isEmpty {
                    editActiveModels.insert(mName)
                    let pid = editID.isEmpty ? "new_custom" : editID
                    var avail = inMemoryAvailableModels[pid] ?? []
                    if !avail.contains(mName) {
                        avail.append(mName)
                        inMemoryAvailableModels[pid] = avail.sorted()
                    }
                    rebuildFormFields(index: index)
                }
                isAddingModelID = false
                newModelIDBuffer = ""
                newModelIDCursor = 0
                return true
            case .escape:
                isAddingModelID = false
                newModelIDBuffer = ""
                newModelIDCursor = 0
                return true
            case .character(let c):  leInsert(c, buf: &newModelIDBuffer, cur: &newModelIDCursor); return true
            case .backspace:         leBackspace(buf: &newModelIDBuffer, cur: &newModelIDCursor); return true
            case .delete:            leDeleteForward(buf: &newModelIDBuffer, cur: &newModelIDCursor); return true
            case .arrowLeft, .ctrlB: leMoveLeft(buf: &newModelIDBuffer, cur: &newModelIDCursor); return true
            case .arrowRight, .ctrlF:leMoveRight(buf: &newModelIDBuffer, cur: &newModelIDCursor); return true
            case .ctrlA:             leMoveHome(buf: &newModelIDBuffer, cur: &newModelIDCursor); return true
            case .ctrlE:             leMoveEnd(buf: &newModelIDBuffer, cur: &newModelIDCursor); return true
            case .ctrlK:             leKillToEnd(buf: &newModelIDBuffer, cur: &newModelIDCursor, ring: &formKillRing); return true
            case .ctrlU:             leKillToStart(buf: &newModelIDBuffer, cur: &newModelIDCursor, ring: &formKillRing); return true
            case .ctrlW:             leKillWordBackward(buf: &newModelIDBuffer, cur: &newModelIDCursor, ring: &formKillRing); return true
            case .ctrlY:             leYank(buf: &newModelIDBuffer, cur: &newModelIDCursor, ring: formKillRing); return true
            case .alt(let c) where c == "b": leWordLeft(buf: &newModelIDBuffer, cur: &newModelIDCursor); return true
            case .alt(let c) where c == "f": leWordRight(buf: &newModelIDBuffer, cur: &newModelIDCursor); return true
            default: break
            }
            return true
        }

        if formEditingField != nil {
            switch key {
            case .enter:
                applyEditBuffer()
                return true
            case .escape:
                formEditingField = nil
                formEditBuffer = ""
                formEditCursor = 0
                return true
            case .character(let c):   leInsert(c, buf: &formEditBuffer, cur: &formEditCursor); return true
            case .backspace:          leBackspace(buf: &formEditBuffer, cur: &formEditCursor); return true
            case .delete:             leDeleteForward(buf: &formEditBuffer, cur: &formEditCursor); return true
            case .arrowLeft, .ctrlB:  leMoveLeft(buf: &formEditBuffer, cur: &formEditCursor); return true
            case .arrowRight, .ctrlF: leMoveRight(buf: &formEditBuffer, cur: &formEditCursor); return true
            case .ctrlA:              leMoveHome(buf: &formEditBuffer, cur: &formEditCursor); return true
            case .ctrlE:              leMoveEnd(buf: &formEditBuffer, cur: &formEditCursor); return true
            case .ctrlK:              leKillToEnd(buf: &formEditBuffer, cur: &formEditCursor, ring: &formKillRing); return true
            case .ctrlU:              leKillToStart(buf: &formEditBuffer, cur: &formEditCursor, ring: &formKillRing); return true
            case .ctrlW:              leKillWordBackward(buf: &formEditBuffer, cur: &formEditCursor, ring: &formKillRing); return true
            case .ctrlY:              leYank(buf: &formEditBuffer, cur: &formEditCursor, ring: formKillRing); return true
            case .alt(let c) where c == "b": leWordLeft(buf: &formEditBuffer, cur: &formEditCursor); return true
            case .alt(let c) where c == "f": leWordRight(buf: &formEditBuffer, cur: &formEditCursor); return true
            default: break
            }
            return true
        }
        
        // Modal / Details Key shortcut: pressing 'i' opens model information modal
        if formFieldIndex < formFields.count {
            let label = formFields[formFieldIndex]
            if label.hasPrefix("model:") {
                let modelID = String(label.dropFirst(6))
                if case .character(let c) = key, c == "i" || c == "I" {
                    showModelModal(modelID: modelID)
                    return true
                }
            }
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

    // MARK: - Form Action Handlers

    private func enterEditForm(index: Int) {
        let p = inMemoryProviders[index]
        editID = p.id
        editType = p.type
        editURL = p.url ?? ""
        editKey = p.apiKey ?? ""
        editHF = p.huggingfaceRepo ?? ""
        editEnabled = p.enabled
        editActiveModels = Set(inMemoryActiveModels[p.id] ?? [])
        
        formFieldIndex = 0
        formEditingField = nil
        formEditBuffer = ""
        formError = ""
        
        rebuildFormFields(index: index)
        subScreen = .edit(index)
    }

    private func enterAddForm() {
        editID = ""
        editType = "openai"
        editURL = ""
        editKey = ""
        editHF = ""
        editEnabled = false
        editActiveModels = []
        
        formFieldIndex = 0
        formEditingField = nil
        formEditBuffer = ""
        formError = ""
        
        rebuildFormFields(index: nil)
        subScreen = .addCustom
    }

    private func rebuildFormFields(index: Int?) {
        var baseFields: [String] = []
        if editType == "mlx" {
            baseFields = ["Model Dir / HF Repo", "Active Status"]
        } else if editType == "fireworks" || editType == "huggingface" {
            baseFields = ["API Access Key", "Active Status"]
        } else {
            baseFields = ["ID / Name", "Base API URL", "API Access Key", "Active Status"]
        }

        baseFields.append("Refresh Model List")
        baseFields.append("Add Active Model ID")
        
        // Append loaded available models
        let pid = editID.isEmpty ? "new_custom" : editID
        let available = inMemoryAvailableModels[pid] ?? []
        for model in available {
            baseFields.append("model:\(model)")
        }
        
        baseFields.append("Save Details")
        if index != nil && editType == "openai" { // Custom OpenAI models can be deleted
            baseFields.append("Delete Provider")
        }
        baseFields.append("Cancel")
        
        self.formFields = baseFields
        if formFieldIndex >= formFields.count {
            formFieldIndex = 0
        }
    }

    private func applyEditBuffer() {
        guard let fieldIdx = formEditingField else { return }
        let label = formFields[fieldIdx]
        
        if label.contains("ID / Name") {
            editID = formEditBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if label.contains("Base API URL") {
            editURL = formEditBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if label.contains("API Access Key") {
            editKey = formEditBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if label.contains("Model Dir") {
            editHF = formEditBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        formEditingField = nil
        formEditBuffer = ""
        formEditCursor = 0
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
                if editHF.isEmpty {
                    formError = "Model Dir is required for Local MLX."
                    return
                }
                
                let models = scanMLXModels(dirPath: editHF)
                if models.isEmpty {
                    formError = "No MLX models (.safetensors / config.json) found in directory."
                    return
                }
                
                if editEnabled && editActiveModels.isEmpty {
                    formError = "Must activate at least 1 local model to enable MLX."
                    return
                }
            } else {
                if editType == "fireworks" || editType == "huggingface" {
                    if editEnabled && editKey.isEmpty {
                        formError = "API key is required to activate."
                        return
                    }
                } else {
                    // Custom OpenAI
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
            
            // Sync memory active models list
            inMemoryActiveModels[editID] = Array(editActiveModels).sorted()
            
            subScreen = .list
            listSelectedIndex = 0
            
        } else if label.contains("Delete Provider") {
            if let idx = index {
                let p = inMemoryProviders[idx]
                inMemoryProviders.remove(at: idx)
                inMemoryActiveModels.removeValue(forKey: p.id)
                inMemoryAvailableModels.removeValue(forKey: p.id)
            }
            subScreen = .list
            listSelectedIndex = 0
            
        } else if label.contains("Cancel") {
            formError = ""
            subScreen = .list
            
        } else if label.contains("Active Status") {
            editEnabled = !editEnabled
            
        } else if label.contains("Model Dir / HF Repo") {
            // Launch directory explorer
            openDirectoryExplorer()
            
        } else if label.contains("Add Active Model ID") {
            isAddingModelID = true
            newModelIDBuffer = ""
        } else if label.contains("Refresh Model List") {
            // Trigger loading models
            await refreshActiveModelList(index: index)
            
        } else if label.hasPrefix("model:") {
            let mName = String(label.dropFirst(6))
            if editActiveModels.contains(mName) {
                editActiveModels.remove(mName)
            } else {
                editActiveModels.insert(mName)
            }
            
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
        formEditCursor = formEditBuffer.count  // start at end like a real shell
    }

    private func refreshActiveModelList(index: Int?) async {
        isFetchingModels = true
        formError = ""
        render() // Render loading state immediately
        
        let pid = editID.isEmpty ? "new_custom" : editID
        
        if editType == "mlx" {
            if editHF.isEmpty {
                formError = "Please specify a Model Directory first."
                isFetchingModels = false
                return
            }
            let models = scanMLXModels(dirPath: editHF)
            inMemoryAvailableModels[pid] = models
            if models.isEmpty {
                formError = "No MLX models detected on disk."
            }
        } else {
            // Remote fetch
            var resolvedKey = editKey
            if resolvedKey.isEmpty || resolvedKey == "keychain" {
                resolvedKey = KeychainHelper.get(key: pid) ?? ""
            }
            
            let urlToFetch: String
            if editType == "fireworks" {
                urlToFetch = "https://api.fireworks.ai/inference/v1"
            } else if editType == "huggingface" {
                urlToFetch = "https://router.huggingface.co/v1"
            } else {
                urlToFetch = editURL
            }
            
            if urlToFetch.isEmpty {
                formError = "API URL is required to fetch models."
                isFetchingModels = false
                return
            }
            
            let result = await fetchRemoteModels(url: urlToFetch, apiKey: resolvedKey)
            if let error = result.error {
                formError = "Error: \(error)"
            } else {
                inMemoryAvailableModels[pid] = result.models
            }
        }
        
        isFetchingModels = false
        rebuildFormFields(index: index)
    }

    // MARK: - Directory Explorer

    private func openDirectoryExplorer() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        explorerPath = FileManager.default.fileExists(atPath: editHF) ? editHF : home
        explorerLeftSelectedIndex = 0
        isShowingDirExplorer = true
        refreshExplorer()
    }

    private func refreshExplorer() {
        let contents = getDirectoryContents(path: explorerPath)
        explorerLeftItems = [".."] + contents
        if explorerLeftSelectedIndex >= explorerLeftItems.count {
            explorerLeftSelectedIndex = 0
        }
        
        if explorerLeftItems.isEmpty {
            explorerRightItems = []
        } else {
            let selectedItem = explorerLeftItems[explorerLeftSelectedIndex]
            let subPath: String
            if selectedItem == ".." {
                subPath = (explorerPath as NSString).deletingLastPathComponent
            } else {
                subPath = (explorerPath as NSString).appendingPathComponent(selectedItem)
            }
            explorerRightItems = getFolderContentsPreview(path: subPath)
        }
    }

    private func getDirectoryContents(path: String) -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return contents.filter { name in
            if name.hasPrefix(".") { return false }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    private func getFolderContentsPreview(path: String) -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return contents.filter { !$0.hasPrefix(".") }.sorted()
    }

    private func handleExplorerKey(_ key: InputKey) -> Bool {
        switch key {
        case .arrowDown:
            explorerLeftSelectedIndex = (explorerLeftSelectedIndex + 1) % explorerLeftItems.count
            refreshExplorer()
            return true
        case .arrowUp:
            explorerLeftSelectedIndex = (explorerLeftSelectedIndex - 1 + explorerLeftItems.count) % explorerLeftItems.count
            refreshExplorer()
            return true
        case .enter:
            let selectedItem = explorerLeftItems[explorerLeftSelectedIndex]
            if selectedItem == ".." {
                explorerPath = (explorerPath as NSString).deletingLastPathComponent
            } else {
                explorerPath = (explorerPath as NSString).appendingPathComponent(selectedItem)
            }
            explorerLeftSelectedIndex = 0
            refreshExplorer()
            return true
        case .character(let c):
            if c == "s" || c == "S" {
                editHF = explorerPath
                isShowingDirExplorer = false
                // Auto trigger scan of models on select
                let pid = editID.isEmpty ? "new_custom" : editID
                inMemoryAvailableModels[pid] = scanMLXModels(dirPath: editHF)
                rebuildFormFields(index: subScreenIndex())
                return true
            } else if c == "c" || c == "C" {
                isShowingDirExplorer = false
                return true
            }
        case .escape:
            isShowingDirExplorer = false
            return true
        default:
            break
        }
        return false
    }

    private func subScreenIndex() -> Int? {
        if case .edit(let idx) = subScreen {
            return idx
        }
        return nil
    }

    // MARK: - Scanning & Fetching Helpers

    private func scanMLXModels(dirPath: String) -> [String] {
        let fm = FileManager.default
        var models: [String] = []
        guard !dirPath.isEmpty, fm.fileExists(atPath: dirPath) else { return [] }
        guard let items = try? fm.contentsOfDirectory(atPath: dirPath) else { return [] }
        
        for item in items {
            let itemPath = (dirPath as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: itemPath, isDirectory: &isDir), isDir.boolValue {
                let configPath = (itemPath as NSString).appendingPathComponent("config.json")
                if fm.fileExists(atPath: configPath) {
                    models.append(item)
                }
            }
        }
        return models.sorted()
    }

    private func fetchRemoteModels(url: String, apiKey: String) async -> (models: [String], error: String?) {
        if editType == "huggingface" {
            // Native Hugging Face Hub API for listing text-generation models
            let cleanURL = "https://huggingface.co/api/models?limit=100&pipeline_tag=text-generation"
            guard let requestURL = URL(string: cleanURL) else {
                return ([], "Invalid Hugging Face URL.")
            }
            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 10.0
            
            if !apiKey.isEmpty {
                request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    return ([], "No HTTP response from Hugging Face.")
                }
                if httpResponse.statusCode == 401 {
                    return ([], "Unauthorized (401) - invalid Hugging Face Token.")
                }
                if httpResponse.statusCode != 200 {
                    return ([], "Hugging Face Hub Error \(httpResponse.statusCode).")
                }
                
                struct HFModelItem: Codable {
                    let id: String
                }
                let decoded = try JSONDecoder().decode([HFModelItem].self, from: data)
                return (decoded.map { $0.id }.sorted(), nil)
            } catch {
                return ([], error.localizedDescription)
            }
        }
        
        if editType == "fireworks" {
            // 1. Fetch user's account IDs from GET https://api.fireworks.ai/v1/accounts
            guard let accountsURL = URL(string: "https://api.fireworks.ai/v1/accounts") else {
                return ([], "Invalid URL format.")
            }
            var accRequest = URLRequest(url: accountsURL)
            accRequest.httpMethod = "GET"
            accRequest.timeoutInterval = 10.0
            if !apiKey.isEmpty {
                accRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            
            var userAccountIDs: [String] = []
            do {
                let (data, response) = try await URLSession.shared.data(for: accRequest)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    struct AccountItem: Codable {
                        let name: String
                    }
                    struct AccountsResponse: Codable {
                        let accounts: [AccountItem]
                    }
                    if let decoded = try? JSONDecoder().decode(AccountsResponse.self, from: data) {
                        userAccountIDs = decoded.accounts.compactMap { item -> String? in
                            let parts = item.name.components(separatedBy: "/")
                            return parts.last
                        }
                    }
                }
            } catch {
                // ignore and fallback to public
            }
            
            // 2. Fetch models for "fireworks" (public) and all user account IDs
            var allModels: Set<String> = []
            var lastError: String? = nil
            
            let targets = ["fireworks"] + userAccountIDs
            for target in targets {
                let modelsURLStr = "https://api.fireworks.ai/v1/accounts/\(target)/models"
                guard let url = URL(string: modelsURLStr) else { continue }
                
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 10.0
                if !apiKey.isEmpty {
                    request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else { continue }
                    if httpResponse.statusCode != 200 {
                        if target == "fireworks" {
                            lastError = "Fireworks API Error \(httpResponse.statusCode) (Unauthorized / Invalid Key)."
                        }
                        continue
                    }
                    
                    struct ModelItem: Codable {
                        let id: String
                    }
                    struct ModelResponse: Codable {
                        let models: [ModelItem]
                    }
                    
                    // Handle Fireworks custom API format ("models" field)
                    if let decoded = try? JSONDecoder().decode(ModelResponse.self, from: data) {
                        for m in decoded.models {
                            allModels.insert(m.id)
                        }
                    } else {
                        // Fallback to OpenAI compatible format ("data" field)
                        struct OpenAIModelResponse: Codable {
                            let data: [ModelItem]
                        }
                        if let decoded = try? JSONDecoder().decode(OpenAIModelResponse.self, from: data) {
                            for m in decoded.data {
                                allModels.insert(m.id)
                            }
                        }
                    }
                } catch {
                    lastError = error.localizedDescription
                }
            }
            
            if allModels.isEmpty {
                return ([], lastError ?? "Failed to fetch Fireworks models. Check API Key.")
            }
            return (Array(allModels).sorted(), nil)
        }
        
        // Custom OpenAI compatible models (Ollama, vLLM, etc.)
        var cleanURL = url
        if !cleanURL.hasSuffix("/models") {
            if cleanURL.hasSuffix("/") {
                cleanURL += "models"
            } else {
                cleanURL += "/models"
            }
        }
        
        guard let requestURL = URL(string: cleanURL) else {
            return ([], "Invalid URL format.")
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0
        
        if !apiKey.isEmpty {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return ([], "No HTTP response received.")
            }
            if httpResponse.statusCode == 401 {
                return ([], "Unauthorized (401) - invalid credentials.")
            }
            if httpResponse.statusCode != 200 {
                return ([], "HTTP Error \(httpResponse.statusCode).")
            }
            
            struct ModelItem: Codable {
                let id: String
            }
            struct ModelResponse: Codable {
                let data: [ModelItem]
            }
            
            let decoded = try JSONDecoder().decode(ModelResponse.self, from: data)
            return (decoded.data.map { $0.id }.sorted(), nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }


    private func showModelModal(modelID: String) {
        modalModelID = modelID
        
        if editType == "mlx" {
            modalModelCostIn = "Free (Local inference)"
            modalModelCostOut = "Free (Local inference)"
            modalModelCtx = "Bounded by device Unified Memory (RAM)"
        } else if editType == "fireworks" {
            modalModelCostIn = "$0.20 per M tokens (est.)"
            modalModelCostOut = "$0.80 per M tokens (est.)"
            modalModelCtx = "8k - 32k tokens"
        } else if editType == "huggingface" {
            modalModelCostIn = "Free / Serverless inference"
            modalModelCostOut = "Free / Serverless inference"
            modalModelCtx = "Varies by HF model endpoint"
        } else {
            modalModelCostIn = "Subject to custom host billing"
            modalModelCostOut = "Subject to custom host billing"
            modalModelCtx = "Configured host standard limits"
        }
        
        isShowingModelModal = true
    }

    // MARK: - Rendering Layouts

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

        if isShowingDirExplorer {
            renderDirExplorer(contentX: contentX, contentY: contentY, contentW: contentW, contentH: contentH)
        } else {
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
        }

        // Float Modal on top of everything if active
        if isShowingModelModal {
            renderModelModal()
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
                    
                    // Format display names professionally
                    let dispName: String
                    if p.id == "mlx" {
                        dispName = "Local MLX Models"
                    } else if p.id == "fireworks" {
                        dispName = "Fireworks.AI"
                    } else if p.id == "huggingface" {
                        dispName = "Huggingface"
                    } else {
                        dispName = p.id
                    }
                    
                    let idStr = dispName.padding(toLength: 20, withPad: " ", startingAt: 0)
                    buffer.writeString(x: contentX + 16, y: y, string: idStr, style: style)
                    
                    let detail: String
                    if p.id == "mlx" {
                        detail = p.huggingfaceRepo.map { "models at \($0)" } ?? "model dir unset"
                    } else if p.id == "fireworks" {
                        detail = "fireworks.ai endpoint"
                    } else if p.id == "huggingface" {
                        detail = "huggingface serverless API"
                    } else {
                        detail = p.url ?? ""
                    }
                    let truncatedDetail = detail.count > (contentW - 38) ? String(detail.prefix(contentW - 41)) + "..." : detail
                    buffer.writeString(x: contentX + 38, y: y, string: truncatedDetail, style: isSelected ? style : BIOSStyle.fgGray)
                } else {
                    buffer.writeString(x: contentX + 2, y: y, string: cursor + "[+] Add Custom OpenAI Provider", style: style)
                }
            }
            
        case .edit, .addCustom:
            drawForm(contentX: contentX, contentY: contentY, contentW: contentW, contentH: contentH)
        }
    }

    private func drawForm(contentX: Int, contentY: Int, contentW: Int, contentH: Int) {
        if isFetchingModels {
            let loadingText = [
                "📡 Fetching available models list from endpoint...",
                "Please wait a moment..."
            ]
            drawTextCentered(text: loadingText, x: contentX, y: contentY, w: contentW, h: contentH, style: BIOSStyle.fgYellow + BIOSStyle.bold)
            return
        }

        buffer.writeString(x: contentX, y: contentY, string: "Edit Parameters & Models:", style: BIOSStyle.fgCyan + BIOSStyle.bold)
        
        // Scroll logic for form fields (especially when models table is long)
        let maxDisplayLines = contentH - 4
        var startIdx = 0
        if formFieldIndex >= maxDisplayLines {
            startIdx = formFieldIndex - maxDisplayLines + 1
        }
        
        var displayCount = 0
        for idx in startIdx..<formFields.count {
            if displayCount >= maxDisplayLines { break }
            
            let label = formFields[idx]
            let isSelected = (formFieldIndex == idx)
            let isEditingThis = (formEditingField == idx)
            
            let cursor = isSelected ? "▶ " : "  "
            
            var style = BIOSStyle.fgWhite
            if isSelected {
                style = BIOSStyle.selection + BIOSStyle.bold
            }
            
            let y = contentY + 2 + displayCount
            displayCount += 1
            
            if label.contains("Save Details") || label.contains("Cancel") || label.contains("Delete Provider") {
                let display = isSelected ? "[ \(label) ]" : "  [\(label)]"
                buffer.writeString(x: contentX + 2, y: y, string: display, style: style)
            } else if label.contains("Refresh Model List") {
                let display = isSelected ? "[ \(label) ]" : "  [\(label)]"
                buffer.writeString(x: contentX + 2, y: y, string: display, style: isSelected ? style : BIOSStyle.fgCyan + BIOSStyle.bold)
            } else if label.contains("Add Active Model ID") {
                if isAddingModelID {
                    let prefixStr = cursor + "Enter Model ID:       "
                    buffer.writeString(x: contentX + 2, y: y, string: prefixStr + String(newModelIDBuffer.prefix(newModelIDCursor)), style: BIOSStyle.fgYellow + BIOSStyle.bold)
                    let curX = contentX + 2 + prefixStr.count + newModelIDCursor
                    if newModelIDCursor < newModelIDBuffer.count {
                        let idx = newModelIDBuffer.index(newModelIDBuffer.startIndex, offsetBy: newModelIDCursor)
                        let ch = String(newModelIDBuffer[idx])
                        let rest = String(newModelIDBuffer[newModelIDBuffer.index(after: idx)...])
                        buffer.writeString(x: curX, y: y, string: ch, style: BIOSStyle.reverse + BIOSStyle.bold)
                        buffer.writeString(x: curX + 1, y: y, string: rest, style: BIOSStyle.fgYellow + BIOSStyle.bold)
                    } else {
                        buffer.writeString(x: curX, y: y, string: " ", style: BIOSStyle.reverse + BIOSStyle.bold)
                    }
                } else {
                    let display = isSelected ? "[ \(label) ]" : "  [\(label)]"
                    buffer.writeString(x: contentX + 2, y: y, string: display, style: isSelected ? style : BIOSStyle.fgCyan + BIOSStyle.bold)
                }
            } else if label.contains("Active Status") {
                let valStr = editEnabled ? "Yes (Active)" : "No (Inactive)"
                let display = "Active Status:         \(valStr)"
                buffer.writeString(x: contentX + 2, y: y, string: cursor + display, style: style)
            } else if label.hasPrefix("model:") {
                // Render Model Table Row
                let modelID = String(label.dropFirst(6))
                let isActive = editActiveModels.contains(modelID)
                let checkStr = isActive ? "[X]" : "[ ]"
                let checkStyle = isActive ? BIOSStyle.fgCyan + BIOSStyle.bold : BIOSStyle.fgGray
                
                buffer.writeString(x: contentX + 2, y: y, string: cursor, style: style)
                buffer.writeString(x: contentX + 4, y: y, string: checkStr, style: isSelected ? style : checkStyle)
                
                // Format cost column
                let costStr: String
                if editType == "mlx" {
                    costStr = "Free (Local)"
                } else if editType == "fireworks" {
                    costStr = "$0.20/$0.80 M"
                } else if editType == "huggingface" {
                    costStr = "Free / Server"
                } else {
                    costStr = "Host billing"
                }
                
                let modelIDCol = modelID.count > (contentW - 25) ? String(modelID.prefix(contentW - 28)) + "..." : modelID
                let modelIDPadded = modelIDCol.padding(toLength: contentW - 22, withPad: " ", startingAt: 0)
                
                buffer.writeString(x: contentX + 8, y: y, string: modelIDPadded, style: style)
                buffer.writeString(x: contentX + contentW - 13, y: y, string: costStr, style: isSelected ? style : BIOSStyle.fgGray)
            } else {
                let labelPadded = label.padding(toLength: 22, withPad: " ", startingAt: 0)
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
                    let isPassword = label.contains("API Access Key")
                    let shownBuf = isPassword
                        ? String(repeating: "•", count: formEditBuffer.count)
                        : formEditBuffer
                    let prefixStr = cursor + labelPadded + ": "
                    let pre = String(shownBuf.prefix(formEditCursor))
                    buffer.writeString(x: contentX + 2, y: y, string: prefixStr + pre, style: BIOSStyle.fgYellow + BIOSStyle.bold)
                    let curX = contentX + 2 + prefixStr.count + formEditCursor
                    if formEditCursor < shownBuf.count {
                        let idx = shownBuf.index(shownBuf.startIndex, offsetBy: formEditCursor)
                        let ch = String(shownBuf[idx])
                        let rest = String(shownBuf[shownBuf.index(after: idx)...])
                        buffer.writeString(x: curX, y: y, string: ch, style: BIOSStyle.reverse + BIOSStyle.bold)
                        buffer.writeString(x: curX + 1, y: y, string: rest, style: BIOSStyle.fgYellow + BIOSStyle.bold)
                    } else {
                        buffer.writeString(x: curX, y: y, string: " ", style: BIOSStyle.reverse + BIOSStyle.bold)
                    }
                } else {
                    let display = "\(labelPadded): \(valStr.isEmpty ? "(empty)" : valStr)"
                    buffer.writeString(x: contentX + 2, y: y, string: cursor + display, style: style)
                }
            }
        }
        
        if !formError.isEmpty {
            buffer.writeString(x: contentX + 2, y: contentY + contentH - 1, string: "⚠ \(formError)", style: BIOSStyle.fgYellow + BIOSStyle.bold)
        }
    }

    private func renderDirExplorer(contentX: Int, contentY: Int, contentW: Int, contentH: Int) {
        buffer.writeString(x: contentX, y: contentY, string: "Select Local Model Directory:", style: BIOSStyle.fgCyan + BIOSStyle.bold)
        
        let pathStr = explorerPath.count > (contentW - 8) ? "..." + String(explorerPath.suffix(contentW - 11)) : explorerPath
        buffer.writeString(x: contentX, y: contentY + 1, string: "Path: \(pathStr)", style: BIOSStyle.fgYellow)
        
        let colW = (contentW - 2) / 2
        let listH = contentH - 4
        
        // Draw Left Box (Folders)
        buffer.drawBox(x: contentX, y: contentY + 2, w: colW, h: listH, title: "FOLDERS", borderStyle: .single, boxStyle: BIOSStyle.fgGray, titleStyle: BIOSStyle.fgCyan)
        
        // Draw Right Box (Preview)
        buffer.drawBox(x: contentX + colW + 1, y: contentY + 2, w: colW, h: listH, title: "CONTENTS PREVIEW", borderStyle: .single, boxStyle: BIOSStyle.fgGray, titleStyle: BIOSStyle.fgCyan)
        
        // Populate Left Pane
        for idx in 0..<min(listH - 2, explorerLeftItems.count) {
            let item = explorerLeftItems[idx]
            let isSelected = (explorerLeftSelectedIndex == idx)
            let style = isSelected ? BIOSStyle.selection + BIOSStyle.bold : BIOSStyle.fgWhite
            
            let display = isSelected ? "▶ \(item)" : "  \(item)"
            let truncated = display.count > (colW - 3) ? String(display.prefix(colW - 6)) + "..." : display
            buffer.writeString(x: contentX + 1, y: contentY + 3 + idx, string: truncated.padding(toLength: colW - 2, withPad: " ", startingAt: 0), style: style)
        }
        
        // Populate Right Pane (Preview)
        for idx in 0..<min(listH - 2, explorerRightItems.count) {
            let item = explorerRightItems[idx]
            let style = BIOSStyle.fgGray
            let truncated = item.count > (colW - 3) ? String(item.prefix(colW - 6)) + "..." : item
            buffer.writeString(x: contentX + colW + 2, y: contentY + 3 + idx, string: truncated, style: style)
        }
        
        // Instructions
        let instructions = " [↑/↓] Navigate  [Enter] Open  [S] Select Folder  [C] Cancel "
        buffer.writeStringCentered(x: contentX, y: contentY + listH + 2, w: contentW, string: instructions, style: BIOSStyle.reverse + BIOSStyle.bold)
    }

    private func renderModelModal() {
        let modalW = 55
        let modalH = 12
        let modalX = (termCols - modalW) / 2
        let modalY = (termRows - modalH) / 2
        
        buffer.drawBox(x: modalX, y: modalY, w: modalW, h: modalH, title: "MODEL INFORMATION", borderStyle: .double, boxStyle: BIOSStyle.fgYellow + BIOSStyle.bold, titleStyle: BIOSStyle.fgYellow + BIOSStyle.bold)
        
        // Truncate Model ID inside modal nicely
        let truncID = modalModelID.count > (modalW - 14) ? String(modalModelID.prefix(modalW - 17)) + "..." : modalModelID
        buffer.writeString(x: modalX + 2, y: modalY + 2, string: "Model ID:     \(truncID)", style: BIOSStyle.fgWhite)
        buffer.writeString(x: modalX + 2, y: modalY + 3, string: "Host Engine:  \(editID.uppercased())", style: BIOSStyle.fgWhite)
        
        buffer.writeString(x: modalX + 2, y: modalY + 5, string: "Input Cost:   \(modalModelCostIn)", style: BIOSStyle.fgCyan + BIOSStyle.bold)
        buffer.writeString(x: modalX + 2, y: modalY + 6, string: "Output Cost:  \(modalModelCostOut)", style: BIOSStyle.fgCyan + BIOSStyle.bold)
        
        // Wrap context limit nicely
        let truncCtx = modalModelCtx.count > (modalW - 16) ? String(modalModelCtx.prefix(modalW - 19)) + "..." : modalModelCtx
        buffer.writeString(x: modalX + 2, y: modalY + 8, string: "Context Size: \(truncCtx)", style: BIOSStyle.fgWhite)
        
        buffer.writeStringCentered(x: modalX, y: modalY + modalH - 2, w: modalW, string: "Press [Any Key] to close", style: BIOSStyle.reverse + BIOSStyle.bold)
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
