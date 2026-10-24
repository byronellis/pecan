import Foundation
import FoundationModels
import Logging
import PecanProtocol

private let logger = Logger(label: "com.pecan.server.session")

/// One node of a session tree, backed by a FoundationModels `LanguageModelSession`.
actor ChatSession {
    typealias Emit = @Sendable (SessionEvent.Params.Event) async -> Void

    let info: SessionInfo
    /// The connection that opened the session. Sessions are not persisted yet, so they end with it.
    let owner: UUID
    private let session: LanguageModelSession
    private var turn: Task<SendMessage.Result, any Error>?

    init(info: SessionInfo, owner: UUID, session: LanguageModelSession) {
        self.info = info
        self.owner = owner
        self.session = session
    }

    var transcript: Transcript { session.transcript }

    func prewarm() {
        session.prewarm()
    }

    /// Runs one turn, streaming the response through `emit`. Cancelling the caller or calling
    /// `cancel()` stops it.
    func send(_ text: String, emit: @escaping Emit) async throws -> SendMessage.Result {
        guard turn == nil else {
            throw RPCError(code: RPCError.sessionBusy, message: "session \(info.id) is already responding")
        }
        logger.debug("session \(info.id): turn started")
        let task = Task { try await self.respond(to: text, emit: emit) }
        turn = task
        defer { turn = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() {
        turn?.cancel()
    }

    private func respond(to text: String, emit: Emit) async throws -> SendMessage.Result {
        var sent = ""
        var usage = TokenUsage.zero
        do {
            for try await snapshot in session.streamResponse(to: text) {
                let content = snapshot.content
                if content.hasPrefix(sent) {
                    let delta = String(content.utf8.dropFirst(sent.utf8.count))!
                    if !delta.isEmpty { await emit(.text(delta)) }
                } else {
                    // Clients append text as it arrives, so a revised prefix can't be shown.
                    logger.warning("session \(info.id): model revised streamed text; dropping the revision")
                }
                sent = content

                let latest = TokenUsage(
                    input: snapshot.usage.input.totalTokenCount,
                    output: snapshot.usage.output.totalTokenCount)
                if latest != usage {
                    usage = latest
                    await emit(.usage(usage))
                }
            }
            try Task.checkCancellation()
        } catch {
            logger.debug("session \(info.id): turn failed: \(error)")
            throw Self.rpcError(for: error)
        }
        logger.debug("session \(info.id): turn finished (\(usage.input) in, \(usage.output) out)")
        return SendMessage.Result(text: sent, usage: usage)
    }

    private static func rpcError(for error: any Error) -> RPCError {
        switch error {
        case let error as RPCError:
            return error
        case is CancellationError:
            return RPCError(code: RPCError.cancelled, message: "turn cancelled")
        case LanguageModelError.contextSizeExceeded:
            return RPCError(code: RPCError.contextExceeded, message: "the conversation no longer fits the model's context window")
        default:
            return RPCError(code: RPCError.generationFailed, message: error.localizedDescription)
        }
    }
}
