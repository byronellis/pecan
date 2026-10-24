import Foundation
import PecanProtocol

extension QuotaStatus {
    /// Short description for status lines, e.g. "quota ok" or "quota reached · resets 3:00 PM".
    var summary: String {
        let reset = resetsAt.map { " · resets \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        switch state {
        case .available: return "quota ok"
        case .approachingLimit: return "quota nearly used" + reset
        case .limitReached: return "quota reached" + reset
        }
    }
}

extension ModelInfo {
    /// Context size, quota and notable capabilities, e.g. "32,768 tokens · quota ok · reasoning".
    var details: String {
        var parts = ["\(contextSize.formatted()) tokens"]
        if let quota { parts.append(quota.summary) }
        if capabilities.contains(.reasoning) { parts.append("reasoning") }
        if capabilities.contains(.vision) { parts.append("vision") }
        return parts.joined(separator: " · ")
    }
}

/// The `/model` list: every model the server knows, with unavailable ones shown but not
/// selectable.
struct ModelPicker {
    let models: [ListModels.Result.Entry]
    let current: ModelID
    private(set) var selected: Int

    init(_ list: ListModels.Result, current: ModelID) {
        models = list.models
        self.current = current
        selected = list.models.firstIndex { $0.id == current } ?? 0
    }

    var selection: ListModels.Result.Entry? {
        models.indices.contains(selected) && models[selected].info != nil ? models[selected] : nil
    }

    /// Moves to the next selectable model in `direction`, if there is one.
    mutating func move(by direction: Int) {
        var index = selected + direction
        while models.indices.contains(index) {
            if models[index].info != nil {
                selected = index
                return
            }
            index += direction
        }
    }

    func rows(width: Int) -> [String] {
        let idWidth = models.map(\.id.count).max() ?? 0
        var rows = [Style.accent + " Switch model" + Style.reset]
        for (index, entry) in models.enumerated() {
            let marker = index == selected ? Style.accent + Style.prompt + Style.reset : " "
            let current = entry.id == self.current ? " (current)" : ""
            let detail = entry.info?.details ?? "unavailable: \(entry.unavailableReason ?? "unknown reason")"
            let text = TextWidth.truncate(
                "\(entry.id.padding(toLength: idWidth, withPad: " ", startingAt: 0))  \(entry.name)\(current) · \(detail)",
                width: max(1, width - 4))
            rows.append(" \(marker) " + (entry.info == nil ? Style.muted + text + Style.reset : text))
        }
        rows.append(Style.muted + " ↑/↓ choose · enter switch · esc cancel" + Style.reset)
        return rows
    }
}
