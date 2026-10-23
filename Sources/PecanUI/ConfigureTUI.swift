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
    private var modifiedProviderIDs: Set<String> = []

    // MARK: - Routing Screen State
    private var routingConfig = RoutingConfig()
    /// Flat list of field labels for the routing form
    private var routingFields: [String] = []
    private var routingFieldIndex: Int = 0
    /// Are we editing a text sub-field on the routing screen?
    private var routingEditingField: Int? = nil
    private var routingEditBuffer: String = ""
    private var routingEditCursor: Int = 0
    /// Picker state: choose a provider+model from configured providers
    private var routingPickerActive = false
    private var routingPickerTarget = ""   // which field the picker writes to
    private var routingPickerIndex = 0
    private var routingPickerItems: [(provider: String, model: String)] = []
    /// Fallback chain entry being edited (index into fallbackChain, or -1 for new)
    private var routingFallbackEditIndex = -1

    // MARK: - Agents Screen State
    private enum AgentsSubScreen {
        case list
        case edit(Int)
        case addCustom
    }
    private var inMemoryAgents: [AgentConfig] = []
    private var agentsSubScreen: AgentsSubScreen = .list
    private var agentsListSelectedIndex: Int = 0
    private var agentsFields: [String] = []
    private var agentsFieldIndex: Int = 0
    private var agentsEditingField: Int? = nil
    private var agentsEditBuffer: String = ""
    private var agentsEditCursor: Int = 0
    private var agentsError: String = ""
    private var agentsPickerActive = false
    private var agentsPickerIndex = 0
    private var agentsPickerItems: [String] = []
    private var agentsPickerTarget = ""

    // Values of the agent currently being edited
    private var editAgentID: String = ""
    private var editAgentName: String = ""
    private var editAgentDescription: String = ""
    private var editAgentSystemPrompt: String = ""
    private var editAgentModel: String? = nil
    private var editAgentEnabled: Bool = true
    private var editAgentAllowedToolTags: [String] = []

    init() {
        let items = [
            TUIMenuItem(id: "providers", label: "Configure Providers", hotkey: "P", isAction: false),
            TUIMenuItem(id: "routing",   label: "Configure Routing",   hotkey: "R", isAction: false),
            TUIMenuItem(id: "agents",    label: "Configure Agents",    hotkey: "A", isAction: false),
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

        // Initialize in-memory configuration state
        let existing = await SettingsStore.shared.allProviders()
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

        // Load routing config
        routingConfig = (try? await SettingsStore.shared.loadRoutingConfig()) ?? RoutingConfig()
        rebuildRoutingFields()

        // Load agents config
        inMemoryAgents = (try? await SettingsStore.shared.allAgents()) ?? []

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

        // Trigger startup model refresh
        Task {
            await refreshAllProviderModels()
        }

        while !shouldExit {
            if let key = nextKey() {
                var handled = false
                let oldSelectedID = sidebarMenu.selectedIndex.map { sidebarMenu.items[$0].id }
                
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
                
                let newSelectedID = sidebarMenu.selectedIndex.map { sidebarMenu.items[$0].id }
                if newSelectedID == "routing" && oldSelectedID != "routing" {
                    Task {
                        await refreshAllProviderModels()
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
        
        // Write the routing config section
        yaml += "routing:\n"
        yaml += "  strategy: \(routingConfig.strategy.rawValue)\n"
        yaml += "  default_route:\n"
        yaml += "    provider: \(routingConfig.defaultRoute.providerID)\n"
        yaml += "    model: \(routingConfig.defaultRoute.modelID)\n"
        if let judge = routingConfig.autoJudgeModel {
            yaml += "  auto_judge_model:\n"
            yaml += "    provider: \(judge.providerID)\n"
            yaml += "    model: \(judge.modelID)\n"
        }
        if !routingConfig.fallbackChain.isEmpty {
            yaml += "  fallback_chain:\n"
            for fb in routingConfig.fallbackChain {
                yaml += "    - provider: \(fb.providerID)\n"
                yaml += "      model: \(fb.modelID)\n"
            }
        }
        if let ctx = routingConfig.contextWindowFallback {
            yaml += "  context_window_fallback:\n"
            yaml += "    provider: \(ctx.providerID)\n"
            yaml += "    model: \(ctx.modelID)\n"
        }
        if let content = routingConfig.contentPolicyFallback {
            yaml += "  content_policy_fallback:\n"
            yaml += "    provider: \(content.providerID)\n"
            yaml += "    model: \(content.modelID)\n"
        }
        yaml += "  circuit_breaker:\n"
        yaml += "    enabled: \(routingConfig.circuitBreakerEnabled)\n"
        yaml += "    fail_threshold: \(routingConfig.circuitBreakerFailThreshold)\n"
        yaml += "    cooldown_seconds: \(routingConfig.circuitBreakerCooldownSeconds)\n"
        yaml += "  budgets:\n"
        yaml += "    enabled: \(routingConfig.budgetEnabled)\n"
        if !routingConfig.providerBudgets.isEmpty {
            yaml += "    provider_budgets:\n"
            for b in routingConfig.providerBudgets {
                yaml += "      \(b.providerID): \(b.dailyLimitUSD)\n"
            }
        }
        
        // Write the agents config section
        if !inMemoryAgents.isEmpty {
            yaml += "agents:\n"
            for a in inMemoryAgents {
                yaml += "  \(a.id):\n"
                yaml += "    name: \"\(a.name)\"\n"
                yaml += "    description: \"\(a.description)\"\n"
                yaml += "    system_prompt: \"\(a.systemPrompt)\"\n"
                if let model = a.model {
                    yaml += "    model: \"\(model)\"\n"
                } else {
                    yaml += "    model: null\n"
                }
                yaml += "    enabled: \(a.enabled)\n"
                yaml += "    allowed_tool_tags: \"\(a.allowedToolTags.joined(separator: ","))\"\n"
            }
        }
        
        return yaml
    }

    private func saveAndFinish() async {
        /*
        // Retrieve currently persistent providers to see what needs deletion
        let existing = (try? await SettingsStore.shared.allProviders()) ?? []
        let existingIDs = Set(existing.map { $0.id })
        let inMemoryIDs = Set(inMemoryProviders.map { $0.id })
        
        let toDelete = existingIDs.subtracting(inMemoryIDs)
        for id in toDelete {
            try? await SettingsStore.shared.deleteProvider(id: id)
            KeychainHelper.delete(key: id)
        }
        
        // Collect all keychain keys to write
        var keychainKeys: [String: String] = [:]
        for p in inMemoryProviders {
            if let key = p.apiKey, !key.isEmpty, key != "keychain" {
                keychainKeys[p.id] = key
            }
        }
        if !keychainKeys.isEmpty {
            _ = KeychainHelper.setMultiple(keychainKeys)
        }
        
        // Write the configured settings back to SQLite DB and Keychain
        for p in inMemoryProviders {
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

        // Sync custom subagents deletion in DB
        let existingAgents = (try? await SettingsStore.shared.allAgents()) ?? []
        let existingAgentIDs = Set(existingAgents.map { $0.id })
        let inMemoryAgentIDs = Set(inMemoryAgents.map { $0.id })
        let agentsToDelete = existingAgentIDs.subtracting(inMemoryAgentIDs)
        for id in agentsToDelete {
            try? await SettingsStore.shared.deleteAgent(id: id)
        }
        
        // Save agents
        for a in inMemoryAgents {
            try? await SettingsStore.shared.saveAgent(a)
        }

        // Save routing config
        try? await SettingsStore.shared.saveRoutingConfig(routingConfig)

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
         */

        shouldExit = true
    }

    private func cancelAndFinish() async {
        shouldExit = true
    }

    // MARK: - Routing Screen Logic

    /// All (providerID, modelID) pairs currently available across configured active models.
    private func allAvailableModelRefs() -> [(provider: String, model: String)] {
        var refs: [(provider: String, model: String)] = []
        for p in inMemoryProviders where p.enabled {
            let active = inMemoryActiveModels[p.id] ?? []
            let available = inMemoryAvailableModels[p.id] ?? []
            let combined = Array(Set(active + available)).sorted()
            for m in combined { refs.append((p.id, m)) }
        }
        return refs
    }

    private func refreshModifiedProvidersIfNeeded() async {
        guard !modifiedProviderIDs.isEmpty else { return }
        isFetchingModels = true
        render() // Render the loading state/indicator immediately
        
        for pid in modifiedProviderIDs {
            guard let provider = inMemoryProviders.first(where: { $0.id == pid }) else { continue }
            if !provider.enabled {
                continue
            }
            
            if provider.id == "mlx" {
                if let repo = provider.huggingfaceRepo {
                    inMemoryAvailableModels["mlx"] = scanMLXModels(dirPath: repo)
                }
            } else if provider.id == "anthropic" {
                inMemoryAvailableModels["anthropic"] = [
                    "claude-3-5-sonnet",
                    "claude-3-5-haiku",
                    "claude-3-opus"
                ]
            } else if provider.id == "mock" {
                inMemoryAvailableModels["mock"] = ["mock"]
            } else {
                let resolvedKey = KeychainHelper.get(key: pid) ?? provider.apiKey ?? ""
                if let url = provider.url, !url.isEmpty {
                    let result = await fetchRemoteModels(url: url, apiKey: resolvedKey)
                    if !result.models.isEmpty {
                        inMemoryAvailableModels[pid] = result.models
                    }
                }
            }
        }
        
        modifiedProviderIDs.removeAll()
        isFetchingModels = false
    }

    private func refreshAllProviderModels() async {
        var didUpdate = false
        for p in inMemoryProviders where p.enabled {
            let pid = p.id
            let existing = inMemoryAvailableModels[pid] ?? []
            if pid == "mlx" {
                if let repo = p.huggingfaceRepo {
                    let models = scanMLXModels(dirPath: repo)
                    if models != existing {
                        inMemoryAvailableModels["mlx"] = models
                        didUpdate = true
                    }
                }
            } else if pid == "anthropic" {
                let models = [
                    "claude-3-5-sonnet",
                    "claude-3-5-haiku",
                    "claude-3-opus"
                ]
                if models != existing {
                    inMemoryAvailableModels["anthropic"] = models
                    didUpdate = true
                }
            } else if pid == "mock" {
                let models = ["mock"]
                if models != existing {
                    inMemoryAvailableModels["mock"] = models
                    didUpdate = true
                }
            } else {
                let resolvedKey = KeychainHelper.get(key: pid) ?? ""
                if let url = p.url, !url.isEmpty {
                    let result = await fetchRemoteModels(url: url, apiKey: resolvedKey)
                    if !result.models.isEmpty && result.models != existing {
                        inMemoryAvailableModels[pid] = result.models
                        didUpdate = true
                    }
                }
            }
        }
        if didUpdate {
            rebuildRoutingFields()
            render()
        }
    }

    private func rebuildRoutingFields() {
        var fields: [String] = []
        fields.append("── DEFAULT ROUTE ──")
        fields.append("Default Provider/Model")
        fields.append("── STRATEGY ──")
        for s in RoutingStrategy.allCases {
            fields.append("strategy:\(s.rawValue)")
        }
        fields.append("── AUTOMATIC ROUTING ──")
        fields.append("Judge Provider/Model")
        fields.append("── FALLBACKS ──")
        for (i, fb) in routingConfig.fallbackChain.enumerated() {
            fields.append("fallback:\(i):\(fb.providerID)/\(fb.modelID)")
        }
        fields.append("Add Fallback")
        fields.append("Context Window Fallback")
        fields.append("Content Policy Fallback")
        fields.append("── CIRCUIT BREAKER ──")
        fields.append("Circuit Breaker Enabled")
        fields.append("Fail Threshold")
        fields.append("Cooldown (seconds)")
        fields.append("── BUDGETS ──")
        fields.append("Budget Limits Enabled")
        for (i, b) in routingConfig.providerBudgets.enumerated() {
            fields.append("budget:\(i):\(b.providerID)")
        }
        fields.append("Add Budget Limit")
        fields.append("Save Routing")
        self.routingFields = fields
        if routingFieldIndex >= routingFields.count { routingFieldIndex = 0 }
    }

    private func openRoutingPicker(target: String) async {
        await refreshModifiedProvidersIfNeeded()
        routingPickerTarget = target
        routingPickerItems = allAvailableModelRefs()
        routingPickerIndex = 0
        routingPickerActive = true
    }

    private func applyRoutingPicker() {
        guard routingPickerIndex < routingPickerItems.count else { return }
        let sel = routingPickerItems[routingPickerIndex]
        let ref = ModelRef(providerID: sel.provider, modelID: sel.model)
        switch routingPickerTarget {
        case "default":  routingConfig.defaultRoute = ref
        case "judge":    routingConfig.autoJudgeModel = ref
        case "ctx":      routingConfig.contextWindowFallback = ref
        case "content":  routingConfig.contentPolicyFallback = ref
        default:
            if routingPickerTarget.hasPrefix("fb:") {
                let idx = Int(routingPickerTarget.dropFirst(3)) ?? -1
                if idx == -1 {
                    routingConfig.fallbackChain.append(ref)
                } else if idx < routingConfig.fallbackChain.count {
                    routingConfig.fallbackChain[idx] = ref
                }
            }
        }
        rebuildRoutingFields()
    }

    private func handleRoutingKey(_ key: InputKey) async -> Bool {
        // ── Picker mode ──────────────────────────────────────────────────────
        if routingPickerActive {
            switch key {
            case .arrowDown:
                routingPickerIndex = (routingPickerIndex + 1) % max(1, routingPickerItems.count)
            case .arrowUp:
                routingPickerIndex = (routingPickerIndex - 1 + max(1, routingPickerItems.count)) % max(1, routingPickerItems.count)
            case .enter:
                applyRoutingPicker()
                routingPickerActive = false
            case .escape:
                routingPickerActive = false
            default: break
            }
            return true
        }

        // ── Text field editing mode ───────────────────────────────────────────
        if routingEditingField != nil {
            switch key {
            case .enter:  applyRoutingEditBuffer(); return true
            case .escape: routingEditingField = nil; routingEditBuffer = ""; routingEditCursor = 0; return true
            case .character(let c):   leInsert(c, buf: &routingEditBuffer, cur: &routingEditCursor); return true
            case .backspace:          leBackspace(buf: &routingEditBuffer, cur: &routingEditCursor); return true
            case .delete:             leDeleteForward(buf: &routingEditBuffer, cur: &routingEditCursor); return true
            case .arrowLeft, .ctrlB:  leMoveLeft(buf: &routingEditBuffer, cur: &routingEditCursor); return true
            case .arrowRight, .ctrlF: leMoveRight(buf: &routingEditBuffer, cur: &routingEditCursor); return true
            case .ctrlA:              leMoveHome(buf: &routingEditBuffer, cur: &routingEditCursor); return true
            case .ctrlE:              leMoveEnd(buf: &routingEditBuffer, cur: &routingEditCursor); return true
            case .ctrlK:              leKillToEnd(buf: &routingEditBuffer, cur: &routingEditCursor, ring: &formKillRing); return true
            case .ctrlU:              leKillToStart(buf: &routingEditBuffer, cur: &routingEditCursor, ring: &formKillRing); return true
            case .ctrlW:              leKillWordBackward(buf: &routingEditBuffer, cur: &routingEditCursor, ring: &formKillRing); return true
            case .ctrlY:              leYank(buf: &routingEditBuffer, cur: &routingEditCursor, ring: formKillRing); return true
            default: break
            }
            return true
        }

        // ── Navigation & actions ─────────────────────────────────────────────
        switch key {
        case .arrowDown:
            routingFieldIndex = (routingFieldIndex + 1) % routingFields.count
            // skip section headers
            while routingFields[routingFieldIndex].hasPrefix("──") {
                routingFieldIndex = (routingFieldIndex + 1) % routingFields.count
            }
            return true
        case .arrowUp:
            routingFieldIndex = (routingFieldIndex - 1 + routingFields.count) % routingFields.count
            while routingFields[routingFieldIndex].hasPrefix("──") {
                routingFieldIndex = (routingFieldIndex - 1 + routingFields.count) % routingFields.count
            }
            return true
        case .escape:
            splitLayout.activePane = .sidebar
            return true
        case .enter:
            await handleRoutingEnter()
            return true
        default:
            break
        }
        return false
    }

    private func applyRoutingEditBuffer() {
        guard let fi = routingEditingField else { return }
        let label = routingFields[fi]
        let val = routingEditBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if label == "Fail Threshold" {
            routingConfig.circuitBreakerFailThreshold = Int(val) ?? routingConfig.circuitBreakerFailThreshold
        } else if label == "Cooldown (seconds)" {
            routingConfig.circuitBreakerCooldownSeconds = Int(val) ?? routingConfig.circuitBreakerCooldownSeconds
        } else if label.hasPrefix("budget:") {
            let parts = label.components(separatedBy: ":")
            if let idx = Int(parts[safe: 1] ?? ""), idx < routingConfig.providerBudgets.count {
                routingConfig.providerBudgets[idx].dailyLimitUSD = Double(val) ?? routingConfig.providerBudgets[idx].dailyLimitUSD
            }
        }
        routingEditingField = nil
        routingEditBuffer = ""
        routingEditCursor = 0
        rebuildRoutingFields()
    }

    private func handleRoutingEnter() async {
        let label = routingFields[routingFieldIndex]
        if label == "Default Provider/Model" {
            await openRoutingPicker(target: "default")
        } else if label == "Judge Provider/Model" {
            await openRoutingPicker(target: "judge")
        } else if label == "Context Window Fallback" {
            await openRoutingPicker(target: "ctx")
        } else if label == "Content Policy Fallback" {
            await openRoutingPicker(target: "content")
        } else if label == "Add Fallback" {
            await openRoutingPicker(target: "fb:-1")
        } else if label == "Add Budget Limit" {
            // Add budget for first provider without one
            let budgetedIDs = Set(routingConfig.providerBudgets.map { $0.providerID })
            let unbudgeted = inMemoryProviders.filter { !budgetedIDs.contains($0.id) }
            if let first = unbudgeted.first {
                routingConfig.providerBudgets.append(ProviderBudget(providerID: first.id, dailyLimitUSD: 10.0))
                rebuildRoutingFields()
            }
        } else if label == "Circuit Breaker Enabled" {
            routingConfig.circuitBreakerEnabled.toggle()
        } else if label == "Budget Limits Enabled" {
            routingConfig.budgetEnabled.toggle()
        } else if label.hasPrefix("strategy:") {
            let raw = String(label.dropFirst(9))
            routingConfig.strategy = RoutingStrategy(rawValue: raw) ?? .simple
        } else if label.hasPrefix("fallback:") {
            let parts = label.components(separatedBy: ":")
            if let idx = Int(parts[safe: 1] ?? "") {
                await openRoutingPicker(target: "fb:\(idx)")
            }
        } else if label.hasPrefix("budget:") {
            let parts = label.components(separatedBy: ":")
            if let idx = Int(parts[safe: 1] ?? ""), idx < routingConfig.providerBudgets.count {
                routingEditingField = routingFieldIndex
                routingEditBuffer = String(routingConfig.providerBudgets[idx].dailyLimitUSD)
                routingEditCursor = routingEditBuffer.count
            }
        } else if label == "Fail Threshold" || label == "Cooldown (seconds)" {
            routingEditingField = routingFieldIndex
            routingEditBuffer = label == "Fail Threshold"
                ? String(routingConfig.circuitBreakerFailThreshold)
                : String(routingConfig.circuitBreakerCooldownSeconds)
            routingEditCursor = routingEditBuffer.count
        } else if label == "Save Routing" {
//            try? await SettingsStore.shared.saveRoutingConfig(routingConfig)
            splitLayout.activePane = .sidebar
        }
    }

    // MARK: - Routing Renderer

    private func renderRoutingScreen(contentX: Int, contentY: Int, contentW: Int, contentH: Int) {
        /*
        if routingPickerActive {
            renderRoutingPicker(contentX: contentX, contentY: contentY, contentW: contentW, contentH: contentH)
            return
        }

        var y = contentY
        let maxY = contentY + contentH - 1

        for (i, label) in routingFields.enumerated() {
            guard y <= maxY else { break }
            let isSelected = (i == routingFieldIndex)
            let selStyle = isSelected ? BIOSStyle.selection + BIOSStyle.bold : BIOSStyle.fgWhite
            let cursor = isSelected ? "▶ " : "  "

            if label.hasPrefix("──") {
                // Section header
                buffer.writeString(x: contentX, y: y, string: label, style: BIOSStyle.fgCyan + BIOSStyle.bold)
                y += 1; continue
            }

            if label == "Default Provider/Model" {
                let val = routingConfig.defaultRoute.providerID.isEmpty ? "(none selected)" : routingConfig.defaultRoute.display
                buffer.writeString(x: contentX, y: y, string: cursor + "Default Route:         \(val)", style: selStyle)
            } else if label.hasPrefix("strategy:") {
                let raw = String(label.dropFirst(9))
                let s = RoutingStrategy(rawValue: raw)!
                let isActive = (routingConfig.strategy == s)
                let indicator = isActive ? "(●) " : "( ) "
                let style = isActive ? BIOSStyle.fgCyan + BIOSStyle.bold : (isSelected ? selStyle : BIOSStyle.fgGray)
                buffer.writeString(x: contentX, y: y, string: cursor + indicator + s.displayName, style: style)
            } else if label == "Judge Provider/Model" {
                let enabled = routingConfig.strategy == .automatic
                let val = routingConfig.autoJudgeModel?.display ?? "(none)"
                let style = enabled ? selStyle : BIOSStyle.fgGray
                buffer.writeString(x: contentX, y: y, string: cursor + "Judge Model:           \(val)" + (enabled ? "" : "  [inactive]"), style: style)
            } else if label.hasPrefix("fallback:") {
                let parts = label.components(separatedBy: ":")
                let idx = Int(parts[safe: 1] ?? "") ?? 0
                let fb = routingConfig.fallbackChain[safe: idx]
                let val = fb?.display ?? "(empty)"
                buffer.writeString(x: contentX, y: y, string: cursor + "  Fallback #\(idx + 1):         \(val)", style: selStyle)
            } else if label == "Add Fallback" {
                buffer.writeString(x: contentX, y: y, string: cursor + "[ Add Fallback Entry ]", style: isSelected ? selStyle : BIOSStyle.fgCyan)
            } else if label == "Context Window Fallback" {
                let val = routingConfig.contextWindowFallback?.display ?? "(none)"
                buffer.writeString(x: contentX, y: y, string: cursor + "Context Overflow:      \(val)", style: selStyle)
            } else if label == "Content Policy Fallback" {
                let val = routingConfig.contentPolicyFallback?.display ?? "(none)"
                buffer.writeString(x: contentX, y: y, string: cursor + "Content Refused:       \(val)", style: selStyle)
            } else if label == "Circuit Breaker Enabled" {
                let v = routingConfig.circuitBreakerEnabled ? "Yes" : "No"
                buffer.writeString(x: contentX, y: y, string: cursor + "Circuit Breaker:       \(v)", style: selStyle)
            } else if label == "Fail Threshold" {
                let editing = routingEditingField == i
                if editing {
                    let pre = String(routingEditBuffer.prefix(routingEditCursor))
                    let post = String(routingEditBuffer.dropFirst(routingEditCursor))
                    buffer.writeString(x: contentX, y: y, string: cursor + "Fail Threshold:        \(pre)", style: BIOSStyle.fgYellow + BIOSStyle.bold)
                    let cx = contentX + 2 + 23 + pre.count
                    buffer.writeString(x: cx, y: y, string: post.isEmpty ? " " : String(post.prefix(1)), style: BIOSStyle.reverse + BIOSStyle.bold)
                    if !post.isEmpty { buffer.writeString(x: cx + 1, y: y, string: String(post.dropFirst()), style: BIOSStyle.fgYellow + BIOSStyle.bold) }
                } else {
                    buffer.writeString(x: contentX, y: y, string: cursor + "Fail Threshold:        \(routingConfig.circuitBreakerFailThreshold)", style: selStyle)
                }
            } else if label == "Cooldown (seconds)" {
                let editing = routingEditingField == i
                if editing {
                    let pre = String(routingEditBuffer.prefix(routingEditCursor))
                    let post = String(routingEditBuffer.dropFirst(routingEditCursor))
                    buffer.writeString(x: contentX, y: y, string: cursor + "Cooldown (secs):       \(pre)", style: BIOSStyle.fgYellow + BIOSStyle.bold)
                    let cx = contentX + 2 + 23 + pre.count
                    buffer.writeString(x: cx, y: y, string: post.isEmpty ? " " : String(post.prefix(1)), style: BIOSStyle.reverse + BIOSStyle.bold)
                    if !post.isEmpty { buffer.writeString(x: cx + 1, y: y, string: String(post.dropFirst()), style: BIOSStyle.fgYellow + BIOSStyle.bold) }
                } else {
                    buffer.writeString(x: contentX, y: y, string: cursor + "Cooldown (secs):       \(routingConfig.circuitBreakerCooldownSeconds)", style: selStyle)
                }
            } else if label == "Budget Limits Enabled" {
                let v = routingConfig.budgetEnabled ? "Yes" : "No"
                buffer.writeString(x: contentX, y: y, string: cursor + "Daily Budgets:         \(v)", style: selStyle)
            } else if label.hasPrefix("budget:") {
                let parts = label.components(separatedBy: ":")
                if let idx = Int(parts[safe: 1] ?? ""), let b = routingConfig.providerBudgets[safe: idx] {
                    let editing = routingEditingField == i
                    if editing {
                        buffer.writeString(x: contentX, y: y, string: cursor + "  \(b.providerID) limit $:  \(routingEditBuffer)", style: BIOSStyle.fgYellow + BIOSStyle.bold)
                    } else {
                        buffer.writeString(x: contentX, y: y, string: cursor + "  \(b.providerID) limit $:  \(String(format: "%.2f", b.dailyLimitUSD))/day", style: selStyle)
                    }
                }
            } else if label == "Add Budget Limit" {
                buffer.writeString(x: contentX, y: y, string: cursor + "[ Add Budget Limit ]", style: isSelected ? selStyle : BIOSStyle.fgCyan)
            } else if label == "Save Routing" {
                buffer.writeString(x: contentX, y: y, string: cursor + "[ Save Routing Config ]", style: isSelected ? selStyle : BIOSStyle.fgWhite + BIOSStyle.bold)
            } else {
                buffer.writeString(x: contentX, y: y, string: cursor + label, style: selStyle)
            }
            y += 1
        }

        let hint = " [↑/↓] Navigate  [Enter] Select/Toggle  [Esc] Back "
        buffer.write(x: contentX, y: maxY, w: contentW, string: hint, style: BIOSStyle.reverse,align: .CENTER)*/
    }

    private func renderRoutingPicker(contentX: Int, contentY: Int, contentW: Int, contentH: Int) {
        /*
        buffer.writeString(x: contentX, y: contentY, string: "Select Provider / Model:", style: BIOSStyle.fgCyan + BIOSStyle.bold)
        let listH = contentH - 3
        buffer.drawBox(x: contentX, y: contentY + 1, w: contentW, h: listH, title: "AVAILABLE MODELS", borderStyle: .single, boxStyle: BIOSStyle.fgGray, titleStyle: BIOSStyle.fgCyan)

        if routingPickerItems.isEmpty {
            buffer.writeString(x: contentX + 2, y: contentY + 3, string: "No active models configured. Add models in Configure Providers first.", style: BIOSStyle.fgGray)
        } else {
            for (i, item) in routingPickerItems.prefix(listH - 2).enumerated() {
                let sel = (i == routingPickerIndex)
                let style = sel ? BIOSStyle.selection + BIOSStyle.bold : BIOSStyle.fgWhite
                let c = sel ? "▶ " : "  "
                buffer.writeString(x: contentX + 1, y: contentY + 2 + i, string: c + item.provider + " / " + item.model, style: style)
            }
        }
        buffer.write(x: contentX, y: contentY + listH + 1, w: contentW, string: " [↑/↓] Navigate  [Enter] Select  [Esc] Cancel ", style: BIOSStyle.reverse,align: .CENTER)
         */
    }

    // MARK: - Main Panel Key Handlers

    private func handleMainPanelKey(_ key: InputKey) async -> Bool {
        let selectedID = sidebarMenu.selectedIndex.map { sidebarMenu.items[$0].id }

        if selectedID == "routing" {
            return await handleRoutingKey(key)
        }

        if selectedID == "agents" {
            return await handleAgentsKey(key)
        }

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
            modifiedProviderIDs.insert(editID)
            
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
            /*
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
            } */
        }

        // 2. Draw Main Panel Box
        /*
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
        case "routing":   mainTitle = "ROUTING CONFIGURATION"
        case "agents":
            switch agentsSubScreen {
            case .list:        mainTitle = "AGENTS CONFIGURATION"
            case .edit:        mainTitle = "EDIT AGENT PARAMETERS"
            case .addCustom:   mainTitle = "ADD CUSTOM SUBAGENT"
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

            case "routing":
                renderRoutingScreen(contentX: contentX, contentY: contentY, contentW: contentW, contentH: contentH)

            case "agents":
                renderAgentsScreen(contentX: contentX, contentY: contentY, contentW: contentW, contentH: contentH)

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
                    "  [R] Configure Routing",
                    "  [A] Configure Agents",
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
        let helpBar = " [↑/↓] Navigate   [Enter] Select   [Esc] Back   [P] Providers   [R] Routing   [A] Agents   [S] Save   [C] Cancel"
        buffer.writeString(x: 0, y: helpY, string: helpBar.padding(toLength: w, withPad: " ", startingAt: 0), style: BIOSStyle.reverse + BIOSStyle.bold)
        
        let credit = " Pecan UI Config Editor v2.0"
        buffer.writeString(x: 0, y: h - 1, string: credit.padding(toLength: w - 1, withPad: " ", startingAt: 0), style: BIOSStyle.fgGray)

        print(buffer.renderString(), terminator: "")
        fflush(stdout) */
    }

    private func renderProvidersScreen(contentX: Int, contentY: Int, contentW: Int, contentH: Int) {
     /*   switch subScreen {
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
        }*/
    }

    private func drawForm(contentX: Int, contentY: Int, contentW: Int, contentH: Int) {
       /* if isFetchingModels {
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
        }*/
    }

    private func renderDirExplorer(contentX: Int, contentY: Int, contentW: Int, contentH: Int) {
       /* buffer.writeString(x: contentX, y: contentY, string: "Select Local Model Directory:", style: BIOSStyle.fgCyan + BIOSStyle.bold)
        
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
        buffer.write(x: contentX, y: contentY + listH + 2, w: contentW, string: instructions, style: BIOSStyle.reverse + BIOSStyle.bold,align: .CENTER) */
    }

    private func renderModelModal() {
/*        let modalW = 55
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
        
        buffer.write(x: modalX, y: modalY + modalH - 2, w: modalW, string: "Press [Any Key] to close", style: BIOSStyle.reverse + BIOSStyle.bold,align: .CENTER) */
    }

    private func drawTextCentered(text: [String], x: Int, y: Int, w: Int, h: Int, style: String = "") {
/*        let startY = y + max(0, (h - text.count) / 2)
        for (idx, line) in text.enumerated() {
            buffer.write(x: x, y: startY + idx, w: w, string: line, style: style,align: .CENTER)
        } */
    }

    // MARK: - Agents Helper Methods

    private func rebuildAgentsFields() {
        var fields: [String] = []
        switch agentsSubScreen {
        case .list:
            break
        case .edit(let idx):
            if idx < inMemoryAgents.count {
                let agent = inMemoryAgents[idx]
                if agent.id == "general" || agent.id == "planning" || agent.id == "coordinator" {
                    // Built-in agents have read-only ID
                    fields.append("Agent ID")
                } else {
                    fields.append("Agent ID")
                }
            } else {
                fields.append("Agent ID")
            }
            fields.append("Agent Name")
            fields.append("Description")
            fields.append("System Prompt")
            fields.append("Model Override")
            fields.append("Allowed Tool Tags")
            fields.append("Active Status")
            fields.append("Save Details")
            fields.append("Cancel")
            if idx < inMemoryAgents.count {
                let agent = inMemoryAgents[idx]
                if agent.id != "general" && agent.id != "planning" && agent.id != "coordinator" {
                    fields.append("Delete Agent")
                }
            }
        case .addCustom:
            fields.append("Agent ID")
            fields.append("Agent Name")
            fields.append("Description")
            fields.append("System Prompt")
            fields.append("Model Override")
            fields.append("Allowed Tool Tags")
            fields.append("Active Status")
            fields.append("Save Details")
            fields.append("Cancel")
        }
        agentsFields = fields
        if agentsFieldIndex >= agentsFields.count { agentsFieldIndex = 0 }
    }

    private func enterAgentEditForm(index: Int) {
        guard index < inMemoryAgents.count else { return }
        let a = inMemoryAgents[index]
        editAgentID = a.id
        editAgentName = a.name
        editAgentDescription = a.description
        editAgentSystemPrompt = a.systemPrompt
        editAgentModel = a.model
        editAgentEnabled = a.enabled
        editAgentAllowedToolTags = a.allowedToolTags
        
        agentsSubScreen = .edit(index)
        agentsFieldIndex = 0
        agentsEditingField = nil
        agentsError = ""
        rebuildAgentsFields()
    }

    private func enterAgentAddForm() {
        editAgentID = ""
        editAgentName = ""
        editAgentDescription = ""
        editAgentSystemPrompt = ""
        editAgentModel = nil
        editAgentEnabled = true
        editAgentAllowedToolTags = ["core", "web", "skills"]
        
        agentsSubScreen = .addCustom
        agentsFieldIndex = 0
        agentsEditingField = nil
        agentsError = ""
        rebuildAgentsFields()
    }

    private func saveAgentDetails(isNew: Bool, index: Int?) {
        let cleanID = editAgentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleanID.isEmpty {
            agentsError = "Agent ID is required."
            return
        }
        if isNew {
            if inMemoryAgents.contains(where: { $0.id == cleanID }) {
                agentsError = "An agent with ID '\(cleanID)' already exists."
                return
            }
        }
        
        let agent = AgentConfig(
            id: cleanID,
            name: editAgentName.isEmpty ? editAgentID : editAgentName,
            description: editAgentDescription,
            systemPrompt: editAgentSystemPrompt,
            model: editAgentModel,
            enabled: editAgentEnabled,
            allowedToolTags: editAgentAllowedToolTags
        )
        
        if isNew {
            inMemoryAgents.append(agent)
        } else if let idx = index, idx < inMemoryAgents.count {
            inMemoryAgents[idx] = agent
        }
        
        agentsSubScreen = .list
        agentsError = ""
    }

    private func deleteAgentDetails(index: Int) {
        guard index < inMemoryAgents.count else { return }
        inMemoryAgents.remove(at: index)
        agentsSubScreen = .list
        agentsError = ""
    }

    private func openAgentsPicker(target: String) async {
        await refreshModifiedProvidersIfNeeded()
        agentsPickerTarget = target
        
        var items = ["Default Model"]
        let refs = allAvailableModelRefs()
        for ref in refs {
            items.append("\(ref.provider)/\(ref.model)")
        }
        agentsPickerItems = items
        agentsPickerIndex = 0
        agentsPickerActive = true
    }

    private func applyAgentsPicker() {
        guard agentsPickerIndex < agentsPickerItems.count else { return }
        let sel = agentsPickerItems[agentsPickerIndex]
        if sel == "Default Model" {
            editAgentModel = nil
        } else {
            editAgentModel = sel
        }
        agentsPickerActive = false
    }

    private func drawAgentForm(contentX: Int, contentY: Int, contentW: Int, contentH: Int) {
/*        buffer.writeString(x: contentX, y: contentY, string: "Edit Agent Parameters:", style: BIOSStyle.fgCyan + BIOSStyle.bold)
        
        let maxDisplayLines = contentH - 4
        var startIdx = 0
        if agentsFieldIndex >= maxDisplayLines {
            startIdx = agentsFieldIndex - maxDisplayLines + 1
        }
        
        var displayCount = 0
        for idx in startIdx..<agentsFields.count {
            if displayCount >= maxDisplayLines { break }
            
            let label = agentsFields[idx]
            let isSelected = (agentsFieldIndex == idx)
            let isEditingThis = (agentsEditingField == idx)
            let cursor = isSelected ? "▶ " : "  "
            
            var style = BIOSStyle.fgWhite
            if isSelected {
                style = BIOSStyle.selection + BIOSStyle.bold
            }
            
            let y = contentY + 2 + displayCount
            displayCount += 1
            
            if label == "Save Details" || label == "Cancel" || label == "Delete Agent" {
                let display = isSelected ? "[ \(label) ]" : "  [\(label)]"
                buffer.writeString(x: contentX + 2, y: y, string: display, style: style)
            } else if label == "Active Status" {
                let valStr = editAgentEnabled ? "Yes (Active)" : "No (Inactive)"
                let display = "Active Status:         \(valStr)"
                buffer.writeString(x: contentX + 2, y: y, string: cursor + display, style: style)
            } else if label == "Model Override" {
                let valStr = editAgentModel ?? "Default Model"
                let display = "Model Override:        \(valStr)"
                buffer.writeString(x: contentX + 2, y: y, string: cursor + display, style: style)
            } else {
                let labelPadded = label.padding(toLength: 22, withPad: " ", startingAt: 0)
                var valStr = ""
                if label == "Agent ID" {
                    valStr = editAgentID
                } else if label == "Agent Name" {
                    valStr = editAgentName
                } else if label == "Description" {
                    valStr = editAgentDescription
                } else if label == "System Prompt" {
                    valStr = editAgentSystemPrompt
                } else if label == "Allowed Tool Tags" {
                    valStr = editAgentAllowedToolTags.joined(separator: ",")
                }
                
                if isEditingThis {
                    let prefixStr = cursor + labelPadded + ": "
                    let pre = String(agentsEditBuffer.prefix(agentsEditCursor))
                    buffer.writeString(x: contentX + 2, y: y, string: prefixStr + pre, style: BIOSStyle.fgYellow + BIOSStyle.bold)
                    let curX = contentX + 2 + prefixStr.count + agentsEditCursor
                    if agentsEditCursor < agentsEditBuffer.count {
                        let idx = agentsEditBuffer.index(agentsEditBuffer.startIndex, offsetBy: agentsEditCursor)
                        let ch = String(agentsEditBuffer[idx])
                        let rest = String(agentsEditBuffer[agentsEditBuffer.index(after: idx)...])
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
        
        if !agentsError.isEmpty {
            buffer.writeString(x: contentX + 2, y: contentY + contentH - 1, string: "⚠ \(agentsError)", style: BIOSStyle.fgYellow + BIOSStyle.bold)
        } */
    }

    private func renderAgentsScreen(contentX: Int, contentY: Int, contentW: Int, contentH: Int) {
/*        if agentsPickerActive {
            renderAgentsPicker(contentX: contentX, contentY: contentY, contentW: contentW, contentH: contentH)
            return
        }
        
        switch agentsSubScreen {
        case .list:
            buffer.writeString(x: contentX, y: contentY, string: "Configure Agents & Subagents:", style: BIOSStyle.fgCyan + BIOSStyle.bold)
            
            for idx in 0..<(inMemoryAgents.count + 1) {
                let isSelected = (agentsListSelectedIndex == idx) && (splitLayout.activePane == .mainPanel)
                let cursor = isSelected ? "▶ " : "  "
                
                var style = BIOSStyle.fgWhite
                if isSelected {
                    style = BIOSStyle.selection + BIOSStyle.bold
                }
                
                let y = contentY + 2 + idx
                
                if idx < inMemoryAgents.count {
                    let a = inMemoryAgents[idx]
                    let statusBadge = a.enabled ? "● Active  " : "○ Inactive"
                    let badgeStyle = a.enabled ? BIOSStyle.fgCyan + BIOSStyle.bold : BIOSStyle.fgGray
                    
                    buffer.writeString(x: contentX + 2, y: y, string: cursor, style: style)
                    buffer.writeString(x: contentX + 4, y: y, string: statusBadge, style: isSelected ? style : badgeStyle)
                    
                    let idStr = a.id.padding(toLength: 15, withPad: " ", startingAt: 0)
                    buffer.writeString(x: contentX + 16, y: y, string: idStr, style: style)
                    
                    let modelStr = a.model ?? "Default"
                    let modelPadded = modelStr.padding(toLength: 20, withPad: " ", startingAt: 0)
                    buffer.writeString(x: contentX + 33, y: y, string: modelPadded, style: isSelected ? style : BIOSStyle.fgGray)
                    
                    let desc = a.description
                    let truncatedDesc = desc.count > (contentW - 55) ? String(desc.prefix(contentW - 58)) + "..." : desc
                    buffer.writeString(x: contentX + 55, y: y, string: truncatedDesc, style: isSelected ? style : BIOSStyle.fgGray)
                } else {
                    buffer.writeString(x: contentX + 2, y: y, string: cursor + "[+] Add Custom Subagent", style: style)
                }
            }
            
        case .edit, .addCustom:
            drawAgentForm(contentX: contentX, contentY: contentY, contentW: contentW, contentH: contentH)
        } */
    }

    private func renderAgentsPicker(contentX: Int, contentY: Int, contentW: Int, contentH: Int) {
/*        buffer.writeString(x: contentX, y: contentY, string: "Select Model for Agent:", style: BIOSStyle.fgCyan + BIOSStyle.bold)
        
        let listH = contentH - 4
        let startIdx = max(0, agentsPickerIndex - listH + 1)
        
        var displayCount = 0
        for idx in startIdx..<agentsPickerItems.count {
            if displayCount >= listH { break }
            let item = agentsPickerItems[idx]
            let isSelected = (agentsPickerIndex == idx)
            let cursor = isSelected ? "▶ " : "  "
            var style = BIOSStyle.fgWhite
            if isSelected {
                style = BIOSStyle.selection + BIOSStyle.bold
            }
            let y = contentY + 2 + displayCount
            displayCount += 1
            
            buffer.writeString(x: contentX + 2, y: y, string: cursor + item, style: style)
        }
        
        buffer.write(x: contentX, y: contentY + listH + 1, w: contentW, string: " [↑/↓] Navigate  [Enter] Select  [Esc] Cancel ", style: BIOSStyle.reverse,align: .CENTER)
 */
    }

    private func handleAgentsKey(_ key: InputKey) async -> Bool {
        if agentsPickerActive {
            switch key {
            case .arrowDown:
                agentsPickerIndex = (agentsPickerIndex + 1) % max(1, agentsPickerItems.count)
            case .arrowUp:
                agentsPickerIndex = (agentsPickerIndex - 1 + max(1, agentsPickerItems.count)) % max(1, agentsPickerItems.count)
            case .enter:
                applyAgentsPicker()
            case .escape:
                agentsPickerActive = false
            default:
                break
            }
            return true
        }
        
        switch agentsSubScreen {
        case .list:
            switch key {
            case .arrowDown:
                agentsListSelectedIndex = (agentsListSelectedIndex + 1) % (inMemoryAgents.count + 1)
                return true
            case .arrowUp:
                agentsListSelectedIndex = (agentsListSelectedIndex - 1 + inMemoryAgents.count + 1) % (inMemoryAgents.count + 1)
                return true
            case .enter:
                if agentsListSelectedIndex < inMemoryAgents.count {
                    enterAgentEditForm(index: agentsListSelectedIndex)
                } else {
                    enterAgentAddForm()
                }
                return true
            case .escape:
                splitLayout.activePane = .sidebar
                return true
            default:
                return false
            }
            
        case .edit(let idx):
            return await handleAgentFormKey(key, isNew: false, index: idx)
        case .addCustom:
            return await handleAgentFormKey(key, isNew: true, index: nil)
        }
    }

    private func handleAgentFormKey(_ key: InputKey, isNew: Bool, index: Int?) async -> Bool {
        if let editingIdx = agentsEditingField {
            switch key {
            case .arrowLeft:
                if agentsEditCursor > 0 { agentsEditCursor -= 1 }
                return true
            case .arrowRight:
                if agentsEditCursor < agentsEditBuffer.count { agentsEditCursor += 1 }
                return true
            case .ctrlA:
                agentsEditCursor = 0
                return true
            case .ctrlE:
                agentsEditCursor = agentsEditBuffer.count
                return true
            case .ctrlK:
                if agentsEditCursor < agentsEditBuffer.count {
                    let idx = agentsEditBuffer.index(agentsEditBuffer.startIndex, offsetBy: agentsEditCursor)
                    formKillRing = String(agentsEditBuffer[idx...])
                    agentsEditBuffer = String(agentsEditBuffer[..<idx])
                }
                return true
            case .ctrlY:
                if !formKillRing.isEmpty {
                    let idx = agentsEditBuffer.index(agentsEditBuffer.startIndex, offsetBy: agentsEditCursor)
                    agentsEditBuffer.insert(contentsOf: formKillRing, at: idx)
                    agentsEditCursor += formKillRing.count
                }
                return true
            case .backspace:
                if agentsEditCursor > 0 {
                    agentsEditCursor -= 1
                    let idx = agentsEditBuffer.index(agentsEditBuffer.startIndex, offsetBy: agentsEditCursor)
                    agentsEditBuffer.remove(at: idx)
                }
                return true
            case .enter:
                applyAgentEditBuffer(fieldIndex: editingIdx)
                agentsEditingField = nil
                return true
            case .escape:
                agentsEditingField = nil
                return true
            case .character(let c):
                let idx = agentsEditBuffer.index(agentsEditBuffer.startIndex, offsetBy: agentsEditCursor)
                agentsEditBuffer.insert(c, at: idx)
                agentsEditCursor += 1
                return true
            default:
                return false
            }
        }
        
        switch key {
        case .arrowDown:
            agentsFieldIndex = (agentsFieldIndex + 1) % max(1, agentsFields.count)
            return true
        case .arrowUp:
            agentsFieldIndex = (agentsFieldIndex - 1 + max(1, agentsFields.count)) % max(1, agentsFields.count)
            return true
        case .enter:
            await handleAgentFormEnter(isNew: isNew, index: index)
            return true
        case .escape:
            agentsSubScreen = .list
            return true
        default:
            return false
        }
    }

    private func applyAgentEditBuffer(fieldIndex: Int) {
        let fieldName = agentsFields[fieldIndex]
        if fieldName == "Agent ID" {
            editAgentID = agentsEditBuffer
        } else if fieldName == "Agent Name" {
            editAgentName = agentsEditBuffer
        } else if fieldName == "Description" {
            editAgentDescription = agentsEditBuffer
        } else if fieldName == "System Prompt" {
            editAgentSystemPrompt = agentsEditBuffer
        } else if fieldName == "Allowed Tool Tags" {
            editAgentAllowedToolTags = agentsEditBuffer.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    private func handleAgentFormEnter(isNew: Bool, index: Int?) async {
        let fieldName = agentsFields[agentsFieldIndex]
        
        if fieldName == "Save Details" {
            saveAgentDetails(isNew: isNew, index: index)
        } else if fieldName == "Cancel" {
            agentsSubScreen = .list
        } else if fieldName == "Delete Agent" {
            if let idx = index {
                deleteAgentDetails(index: idx)
            }
        } else if fieldName == "Active Status" {
            editAgentEnabled.toggle()
        } else if fieldName == "Model Override" {
            await openAgentsPicker(target: "model")
        } else {
            // ID of built-in agent is read-only
            if fieldName == "Agent ID" && !isNew {
                return
            }
            agentsEditingField = agentsFieldIndex
            if fieldName == "Agent ID" {
                agentsEditBuffer = editAgentID
            } else if fieldName == "Agent Name" {
                agentsEditBuffer = editAgentName
            } else if fieldName == "Description" {
                agentsEditBuffer = editAgentDescription
            } else if fieldName == "System Prompt" {
                agentsEditBuffer = editAgentSystemPrompt
            } else if fieldName == "Allowed Tool Tags" {
                agentsEditBuffer = editAgentAllowedToolTags.joined(separator: ",")
            }
            agentsEditCursor = agentsEditBuffer.count
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
