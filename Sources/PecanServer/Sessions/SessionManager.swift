import Foundation
import FoundationModels
import PecanProtocol

/// All live sessions on the server, as a forest of session trees.
actor SessionManager {
    private var sessions: [SessionID: ChatSession] = [:]

    func open(_ params: OpenSession.Params, owner: UUID) throws -> SessionInfo {
        let model = try Self.systemModel()
        let session = LanguageModelSession(model: model, instructions: params.instructions)
        return add(ChatSession(
            info: SessionInfo(id: Self.newID(), parentID: nil, kind: .main, createdAt: Date(),
                              model: Self.info(for: model)),
            owner: owner,
            session: session))
    }

    /// A fork or side conversation starts from a copy of the parent's history; a sub-session
    /// starts empty and reports back to its parent.
    func fork(_ params: ForkSession.Params, owner: UUID) async throws -> SessionInfo {
        let parent = try session(params.sessionID)
        guard params.kind != .main else {
            throw RPCError(code: RPCError.invalidParams, message: "a main session has no parent; use \(OpenSession.name)")
        }
        let model = try Self.systemModel()
        let session = params.kind == .sub
            ? LanguageModelSession(model: model)
            : LanguageModelSession(model: model, transcript: await parent.transcript)
        return add(ChatSession(
            info: SessionInfo(id: Self.newID(), parentID: params.sessionID, kind: params.kind,
                              createdAt: Date(), model: Self.info(for: model)),
            owner: owner,
            session: session))
    }

    func session(_ id: SessionID) throws -> ChatSession {
        guard let session = sessions[id] else {
            throw RPCError(code: RPCError.unknownSession, message: "no session \(id)")
        }
        return session
    }

    /// Ends every session a disconnected client opened, cancelling any running turns.
    func closeAll(ownedBy owner: UUID) async {
        let owned = sessions.values.filter { $0.owner == owner }
        for session in owned {
            sessions[session.info.id] = nil
            await session.cancel()
        }
    }

    private func add(_ session: ChatSession) -> SessionInfo {
        sessions[session.info.id] = session
        Task { await session.prewarm() }
        return session.info
    }

    private static func newID() -> SessionID {
        UUID().uuidString.lowercased()
    }

    private static func info(for model: SystemLanguageModel) -> ModelInfo {
        ModelInfo(name: "system", contextSize: model.contextSize)
    }

    private static func systemModel() throws -> SystemLanguageModel {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model
        case .unavailable(let reason):
            throw RPCError(code: RPCError.modelUnavailable, message: "the system model is unavailable: \(Self.describe(reason))")
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "this device doesn't support Apple Intelligence"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is turned off in System Settings"
        case .modelNotReady: "the model is still downloading or preparing"
        @unknown default: "\(reason)"
        }
    }
}
