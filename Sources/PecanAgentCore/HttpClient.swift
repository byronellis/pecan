import Foundation
import PecanShared

public actor HttpClient {
    public static let shared = HttpClient()

    private var pendingRequests: [String: CheckedContinuation<Pecan_HttpProxyResponse, Error>] = [:]
    private var sendCallback: (@Sendable (Pecan_AgentEvent) async throws -> Void)?

    public func configure(send: @escaping @Sendable (Pecan_AgentEvent) async throws -> Void) {
        self.sendCallback = send
    }

    public func handleResponse(_ response: Pecan_HttpProxyResponse) {
        guard let continuation = pendingRequests.removeValue(forKey: response.requestID) else { return }
        if !response.errorMessage.isEmpty {
            continuation.resume(throwing: NSError(domain: "HttpClient", code: 1, userInfo: [NSLocalizedDescriptionKey: response.errorMessage]))
        } else {
            continuation.resume(returning: response)
        }
    }

    public func sendRequest(
        method: String,
        url: String,
        headers: [(name: String, value: String)] = [],
        queryParams: [(name: String, value: String)] = [],
        body: String = "",
        requiresApproval: Bool = false
    ) async throws -> Pecan_HttpProxyResponse {
        guard let send = sendCallback else {
            throw NSError(domain: "HttpClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "HttpClient not configured"])
        }
        let requestID = UUID().uuidString

        var msg = Pecan_AgentEvent()
        var req = Pecan_HttpProxyRequest()
        req.requestID = requestID
        req.method = method
        req.url = url
        req.headers = headers.map { h in
            var header = Pecan_HttpHeader()
            header.name = h.name
            header.value = h.value
            return header
        }
        req.queryParams = queryParams.map { q in
            var param = Pecan_HttpQueryParam()
            param.name = q.name
            param.value = q.value
            return param
        }
        req.body = body
        req.requiresApproval = requiresApproval
        msg.httpRequest = req

        try await send(msg)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
        }
    }
}
