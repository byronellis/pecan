import Foundation
import FoundationModels
import PecanProtocol
import Security

/// The models sessions can run on.
enum ModelChoice: String, CaseIterable {
    case pcc
    case system

    /// Preference order for sessions that don't ask for a model: the first available one is
    /// the default. Later this becomes a user setting, so a local CoreAI model can lead instead.
    static let preferred: [ModelChoice] = [.pcc, .system]

    var name: String {
        switch self {
        case .pcc: "Private Cloud Compute"
        case .system: "On-device"
        }
    }
}

/// A model ready to back a session, with what clients are told about it.
struct ResolvedModel {
    let choice: ModelChoice
    let model: any LanguageModel
    let info: ModelInfo
}

enum ModelCatalog {
    private static let privateCloudCompute = PrivateCloudComputeLanguageModel()

    /// The model for `id`, or the default for nil. Throws if it is unknown or unavailable.
    static func resolve(_ id: ModelID?) async throws -> ResolvedModel {
        let choice: ModelChoice
        if let id {
            guard let requested = ModelChoice(rawValue: id) else {
                let known = ModelChoice.allCases.map(\.rawValue).joined(separator: ", ")
                throw RPCError(code: RPCError.invalidParams, message: "unknown model '\(id)'; available: \(known)")
            }
            choice = requested
        } else {
            choice = defaultChoice
        }
        if let reason = unavailableReason(choice) {
            throw RPCError(code: RPCError.modelUnavailable, message: "\(choice.name) is unavailable: \(reason)")
        }
        return ResolvedModel(choice: choice, model: model(choice), info: try await info(choice))
    }

    static func list() async -> ListModels.Result {
        var entries: [ListModels.Result.Entry] = []
        for choice in ModelChoice.allCases {
            let reason = unavailableReason(choice)
            let info = reason == nil ? try? await info(choice) : nil
            entries.append(.init(id: choice.rawValue, name: choice.name, info: info, unavailableReason: reason))
        }
        return ListModels.Result(models: entries, defaultModel: defaultChoice.rawValue)
    }

    private static var defaultChoice: ModelChoice {
        ModelChoice.preferred.first { unavailableReason($0) == nil } ?? ModelChoice.preferred[0]
    }

    /// PCC is a managed entitlement Apple grants on request. Without it the framework still
    /// reports PCC as available, but every request fails (ModelManagerError 1046), so check the
    /// process's own signature instead.
    private static let hasPrivateCloudComputeEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.private-cloud-compute" as CFString, nil)
        return (value as? Bool) == true
    }()

    static func quota(_ choice: ModelChoice) -> QuotaStatus? {
        guard choice == .pcc else { return nil }
        let usage = privateCloudCompute.quotaUsage
        switch usage.status {
        case .belowLimit(let below):
            return QuotaStatus(state: below.isApproachingLimit ? .approachingLimit : .available, resetsAt: usage.resetDate)
        case .limitReached:
            return QuotaStatus(state: .limitReached, resetsAt: usage.resetDate)
        @unknown default:
            return QuotaStatus(state: usage.isLimitReached ? .limitReached : .available, resetsAt: usage.resetDate)
        }
    }

    private static func model(_ choice: ModelChoice) -> any LanguageModel {
        switch choice {
        case .pcc: privateCloudCompute
        case .system: SystemLanguageModel.default
        }
    }

    private static func info(_ choice: ModelChoice) async throws -> ModelInfo {
        let contextSize = switch choice {
        case .pcc: try await privateCloudCompute.contextSize
        case .system: SystemLanguageModel.default.contextSize
        }
        return ModelInfo(id: choice.rawValue, name: choice.name, contextSize: contextSize,
                         quota: quota(choice), capabilities: capabilities(of: model(choice)))
    }

    private static func capabilities(of model: any LanguageModel) -> Set<ModelInfo.Capability> {
        let mapping: [(ModelInfo.Capability, LanguageModelCapabilities.Capability)] = [
            (.toolCalling, .toolCalling),
            (.guidedGeneration, .guidedGeneration),
            (.vision, .vision),
            (.reasoning, .reasoning),
        ]
        return Set(mapping.filter { model.capabilities.contains($0.1) }.map(\.0))
    }

    private static func unavailableReason(_ choice: ModelChoice) -> String? {
        switch choice {
        case .pcc:
            guard hasPrivateCloudComputeEntitlement else {
                return "this build isn't signed with the com.apple.developer.private-cloud-compute entitlement"
            }
            switch privateCloudCompute.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "this device isn't eligible for Private Cloud Compute"
            case .unavailable(.systemNotReady): return "Private Cloud Compute isn't ready yet"
            case .unavailable(let reason): return "\(reason)"
            }
        case .system:
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "this device doesn't support Apple Intelligence"
            case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is turned off in System Settings"
            case .unavailable(.modelNotReady): return "the model is still downloading or preparing"
            case .unavailable(let reason): return "\(reason)"
            }
        }
    }
}
