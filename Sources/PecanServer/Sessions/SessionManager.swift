import Foundation
import FoundationModels
import PecanProtocol

/// All live sessions on the server, as a forest of session trees.
actor SessionManager {
    private var sessions: [SessionID: ChatSession] = [:]

    func open(_ params: OpenSession.Params, owner: UUID) async throws -> SessionInfo {
        let resolved = try await ModelCatalog.resolve(params.model)
        let session = LanguageModelSession(model: resolved.model, instructions: params.instructions)
        return await add(ChatSession(
            info: SessionInfo(id: Self.newID(), parentID: nil, kind: .main, createdAt: Date(), model: resolved.info),
            model: resolved.choice,
            owner: owner,
            session: session))
    }

    /// A fork or side conversation starts from a copy of the parent's history; a sub-session
    /// starts empty and reports back to its parent. Children use the parent's model unless the
    /// request names another.
    func fork(_ params: ForkSession.Params, owner: UUID) async throws -> SessionInfo {
        let parent = try session(params.sessionID)
        let parentInfo = await parent.info
        guard params.kind != .main else {
            throw RPCError(code: RPCError.invalidParams, message: "a main session has no parent; use \(OpenSession.name)")
        }
        let resolved = try await ModelCatalog.resolve(params.model ?? parentInfo.model.id)
        let session = params.kind == .sub
            ? LanguageModelSession(model: resolved.model)
            : LanguageModelSession(model: resolved.model, transcript: await parent.transcript)
        return await add(ChatSession(
            info: SessionInfo(id: Self.newID(), parentID: params.sessionID, kind: params.kind,
                              createdAt: Date(), model: resolved.info),
            model: resolved.choice,
            owner: owner,
            session: session))
    }

    func setModel(_ params: SetSessionModel.Params) async throws -> SessionInfo {
        let resolved = try await ModelCatalog.resolve(params.model)
        return try await session(params.sessionID).switchModel(to: resolved)
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
            sessions[session.id] = nil
            await session.cancel()
        }
    }

    private func add(_ session: ChatSession) async -> SessionInfo {
        sessions[session.id] = session
        Task { await session.prewarm() }
        return await session.info
    }

    private static func newID() -> SessionID {
        UUID().uuidString.lowercased()
    }
}
