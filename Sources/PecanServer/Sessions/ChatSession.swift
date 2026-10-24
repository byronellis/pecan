import Foundation
import FoundationModels
import Logging
import PecanProtocol

private let logger = Logger(label: "com.pecan.server.session")

/// One node of a session tree, backed by a FoundationModels `LanguageModelSession`.
actor ChatSession {
    typealias Emit = @Sendable (SessionEvent.Params.Event) async -> Void

    let id: SessionID
    /// The connection that opened the session. Sessions are not persisted yet, so they end with it.
    let owner: UUID
    private(set) var info: SessionInfo
    private var model: ModelChoice
    private var session: LanguageModelSession
    private var turn: Task<SendMessage.Result, any Error>?

    init(info: SessionInfo, model: ModelChoice, owner: UUID, session: LanguageModelSession) {
        self.id = info.id
        self.info = info
        self.model = model
        self.owner = owner
        self.session = session
    }

    var transcript: Transcript { session.transcript }

    func prewarm() {
        session.prewarm()
    }

    /// Continues the conversation on another model, carrying its history over.
    func switchModel(to resolved: ResolvedModel) throws -> SessionInfo {
        guard turn == nil else {
            throw RPCError(code: RPCError.sessionBusy, message: "can't change models while session \(id) is responding")
        }
        session = LanguageModelSession(model: resolved.model, transcript: session.transcript)
        model = resolved.choice
        info.model = resolved.info
        session.prewarm()
        return info
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
        return SendMessage.Result(text: sent, usage: usage, quota: ModelCatalog.quota(model))
    }

    private static func rpcError(for error: any Error) -> RPCError {
        switch error {
        case let error as RPCError:
            return error
        case is CancellationError:
            return RPCError(code: RPCError.cancelled, message: "turn cancelled")
        case LanguageModelError.contextSizeExceeded:
            return RPCError(code: RPCError.contextExceeded, message: "the conversation no longer fits the model's context window")
        case PrivateCloudComputeLanguageModel.Error.quotaLimitReached(let limit):
            let reset = limit.resetDate.map { " until \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            return RPCError(code: RPCError.quotaExceeded, message: "Private Cloud Compute quota reached\(reset)")
        case PrivateCloudComputeLanguageModel.Error.networkFailure:
            return RPCError(code: RPCError.modelUnavailable, message: "couldn't reach Private Cloud Compute; check the network connection")
        case PrivateCloudComputeLanguageModel.Error.serviceUnavailable:
            return RPCError(code: RPCError.modelUnavailable, message: "Private Cloud Compute is unavailable right now")
        default:
            return RPCError(code: RPCError.generationFailed, message: error.localizedDescription)
        }
    }
}
