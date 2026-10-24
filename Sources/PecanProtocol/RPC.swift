import Foundation
import PecanSettings

/// Version of the client/server wire protocol. Bump on changes older peers can't handle.
public let pecanProtocolVersion = 3

/// A JSON-RPC 2.0 method with typed parameters and result.
public protocol RPCMethod {
    associatedtype Params: Codable & Sendable
    associatedtype Result: Codable & Sendable
    static var name: String { get }
}

public struct Empty: Codable, Sendable, Equatable {
    public init() {}
}

public struct RPCError: Error, Codable, Sendable, CustomStringConvertible {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603

    // Pecan application errors (the JSON-RPC server-error range).
    public static let modelUnavailable = -32000
    public static let unknownSession = -32001
    public static let sessionBusy = -32002
    public static let contextExceeded = -32003
    public static let cancelled = -32004
    public static let generationFailed = -32005
    public static let quotaExceeded = -32006

    public var description: String { "\(message) (\(code))" }
}

/// Fields common to every message, decoded first to route the full payload.
public struct RPCHeader: Decodable, Sendable {
    public var id: Int?
    public var method: String?
    public var error: RPCError?
}

public struct RPCRequest<Params: Codable & Sendable>: Codable, Sendable {
    public var jsonrpc = "2.0"
    public var id: Int
    public var method: String
    public var params: Params

    public init(id: Int, method: String, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct RPCResponse<Result: Codable & Sendable>: Codable, Sendable {
    public var jsonrpc = "2.0"
    public var id: Int?
    public var result: Result?
    public var error: RPCError?

    public init(id: Int?, result: Result) {
        self.id = id
        self.result = result
    }

    public init(id: Int?, error: RPCError) {
        self.id = id
        self.error = error
    }
}

/// A message with no `id` that expects no reply; the server streams session events this way.
public struct RPCNotification<Params: Codable & Sendable>: Codable, Sendable {
    public var jsonrpc = "2.0"
    public var method: String
    public var params: Params

    public init(method: String, params: Params) {
        self.method = method
        self.params = params
    }
}

/// A notification type with typed parameters.
public protocol RPCNotificationMethod {
    associatedtype Params: Codable & Sendable
    static var name: String { get }
}

public enum RPCCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Methods

/// First message on every connection: exchanges builds so the client can decide whether to
/// upgrade the server.
public enum Hello: RPCMethod {
    public static let name = "hello"

    public struct Params: Codable, Sendable {
        public var build: BuildInfo
        public var protocolVersion: Int

        public init(build: BuildInfo, protocolVersion: Int) {
            self.build = build
            self.protocolVersion = protocolVersion
        }
    }

    public struct Result: Codable, Sendable {
        public var build: BuildInfo
        public var protocolVersion: Int
        public var pid: Int32

        public init(build: BuildInfo, protocolVersion: Int, pid: Int32) {
            self.build = build
            self.protocolVersion = protocolVersion
            self.pid = pid
        }
    }
}

public enum Shutdown: RPCMethod {
    public static let name = "shutdown"

    public enum Reason: String, Codable, Sendable {
        /// Explicit `pecan server stop`.
        case stop
        /// A newer client is replacing this server.
        case upgrade
    }

    public struct Params: Codable, Sendable {
        public var reason: Reason

        public init(reason: Reason) {
            self.reason = reason
        }
    }

    public typealias Result = Empty
}

public enum GetStatus: RPCMethod {
    public static let name = "status"

    public typealias Params = Empty

    public struct Result: Codable, Sendable {
        public var build: BuildInfo
        public var pid: Int32
        public var startedAt: Date
        public var connectedClients: Int

        public init(build: BuildInfo, pid: Int32, startedAt: Date, connectedClients: Int) {
            self.build = build
            self.pid = pid
            self.startedAt = startedAt
            self.connectedClients = connectedClients
        }
    }
}
