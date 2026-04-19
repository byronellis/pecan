import Foundation
import PecanShared

/// Routes LLM completion responses to waiting subagent sessions by request ID.
/// The main agent's `AgentEventHandler` calls `fulfill` for every completion response;
/// if it returns `true`, the response was claimed by a subagent and the handler skips it.
public actor CompletionRouter {
    public static let shared = CompletionRouter()

    private var pending: [String: AsyncStream<Pecan_LLMCompletionResponse>.Continuation] = [:]

    public init() {}

    /// Create an `AsyncStream` that will yield exactly one response for `requestID`.
    /// The registration is performed atomically (before returning) so callers can
    /// safely send the completion request immediately after awaiting this method.
    public func makeStream(requestID: String) -> AsyncStream<Pecan_LLMCompletionResponse> {
        var cont: AsyncStream<Pecan_LLMCompletionResponse>.Continuation!
        let stream = AsyncStream(Pecan_LLMCompletionResponse.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            cont = continuation
        }
        pending[requestID] = cont
        return stream
    }

    /// Deliver a response to the registered waiter. Returns `true` if the request ID
    /// belonged to a subagent (handler should not process it as a main-agent response).
    @discardableResult
    public func fulfill(requestID: String, response: Pecan_LLMCompletionResponse) -> Bool {
        guard let cont = pending.removeValue(forKey: requestID) else { return false }
        cont.yield(response)
        cont.finish()
        return true
    }
}
