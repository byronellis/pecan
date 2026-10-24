import Foundation

// Sessions form trees: a main session at the root, with
// - sub-sessions: delegated work that starts from a clean context and a task brief, and reports
//   only a summary back into the parent's history, keeping the parent's context small;
// - forks: a copy of the parent's history that continues as its own branch;
// - side conversations: a temporary copy of the parent's history for an aside, closed without
//   feeding anything back.

public typealias SessionID = String

public struct SessionInfo: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case main
        case sub
        case fork
        case side
    }

    public var id: SessionID
    public var parentID: SessionID?
    public var kind: Kind
    public var createdAt: Date
    public var model: ModelInfo

    public init(id: SessionID, parentID: SessionID?, kind: Kind, createdAt: Date, model: ModelInfo) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.createdAt = createdAt
        self.model = model
    }
}

public struct ModelInfo: Codable, Sendable, Equatable {
    /// Short name shown to the user, e.g. "system".
    public var name: String
    /// Context window in tokens.
    public var contextSize: Int

    public init(name: String, contextSize: Int) {
        self.name = name
        self.contextSize = contextSize
    }
}

/// Token counts for one turn. `input` covers everything sent to the model, including the
/// session's history, so `input + output` is how much of the context window the session uses.
public struct TokenUsage: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int

    public init(input: Int, output: Int) {
        self.input = input
        self.output = output
    }

    public static let zero = TokenUsage(input: 0, output: 0)
}

/// Starts a new main session.
public enum OpenSession: RPCMethod {
    public static let name = "session.open"

    public struct Params: Codable, Sendable {
        public var instructions: String?

        public init(instructions: String? = nil) {
            self.instructions = instructions
        }
    }

    public typealias Result = SessionInfo
}

/// Branches a session: the child starts with a copy of the parent's history.
public enum ForkSession: RPCMethod {
    public static let name = "session.fork"

    public struct Params: Codable, Sendable {
        public var sessionID: SessionID
        public var kind: SessionInfo.Kind

        public init(sessionID: SessionID, kind: SessionInfo.Kind = .fork) {
            self.sessionID = sessionID
            self.kind = kind
        }
    }

    public typealias Result = SessionInfo
}

/// Sends a user message and answers once the model's turn ends. The response streams to the
/// sender as `SessionEvent` notifications while the turn runs.
public enum SendMessage: RPCMethod {
    public static let name = "session.send"

    public struct Params: Codable, Sendable {
        public var sessionID: SessionID
        public var text: String

        public init(sessionID: SessionID, text: String) {
            self.sessionID = sessionID
            self.text = text
        }
    }

    public struct Result: Codable, Sendable {
        public var text: String
        public var usage: TokenUsage

        public init(text: String, usage: TokenUsage) {
            self.text = text
            self.usage = usage
        }
    }
}

/// Stops the session's running turn, which then fails with `RPCError.cancelled`.
public enum CancelTurn: RPCMethod {
    public static let name = "session.cancel"

    public struct Params: Codable, Sendable {
        public var sessionID: SessionID

        public init(sessionID: SessionID) {
            self.sessionID = sessionID
        }
    }

    public typealias Result = Empty
}

public enum SessionEvent: RPCNotificationMethod {
    public static let name = "session.event"

    public struct Params: Codable, Sendable {
        public enum Event: Codable, Sendable, Equatable {
            /// More of the response text.
            case text(String)
            case usage(TokenUsage)
        }

        public var sessionID: SessionID
        public var event: Event

        public init(sessionID: SessionID, event: Event) {
            self.sessionID = sessionID
            self.event = event
        }
    }
}
