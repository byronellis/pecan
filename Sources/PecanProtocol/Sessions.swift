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

/// Model ids: `pcc` (Private Cloud Compute) and `system` (the on-device model).
public typealias ModelID = String

public struct ModelInfo: Codable, Sendable, Equatable {
    /// Identifier used to request the model, e.g. "pcc".
    public var id: ModelID
    /// Human-readable name, e.g. "Private Cloud Compute".
    public var name: String
    /// Context window in tokens.
    public var contextSize: Int
    /// Usage limits, for models that have them.
    public var quota: QuotaStatus?
    public var capabilities: Set<Capability>

    public enum Capability: String, Codable, Sendable, CaseIterable {
        case toolCalling
        case guidedGeneration
        case vision
        /// Accepts a thinking level.
        case reasoning
    }

    public init(id: ModelID, name: String, contextSize: Int, quota: QuotaStatus? = nil, capabilities: Set<Capability> = []) {
        self.id = id
        self.name = name
        self.contextSize = contextSize
        self.quota = quota
        self.capabilities = capabilities
    }
}

/// Where a metered model's usage stands. The system reports a state, not an amount remaining.
public struct QuotaStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case available
        case approachingLimit
        case limitReached
    }

    public var state: State
    /// When usage resets, if known.
    public var resetsAt: Date?

    public init(state: State, resetsAt: Date? = nil) {
        self.state = state
        self.resetsAt = resetsAt
    }
}

/// Every model the server knows, whether it can be used right now, and which one sessions get
/// by default.
public enum ListModels: RPCMethod {
    public static let name = "models.list"

    public typealias Params = Empty

    public struct Result: Codable, Sendable {
        public struct Entry: Codable, Sendable {
            public var id: ModelID
            public var name: String
            /// Set when available, along with quota for metered models.
            public var info: ModelInfo?
            /// Why the model can't be used, when it can't.
            public var unavailableReason: String?

            public init(id: ModelID, name: String, info: ModelInfo?, unavailableReason: String?) {
                self.id = id
                self.name = name
                self.info = info
                self.unavailableReason = unavailableReason
            }
        }

        public var models: [Entry]
        public var defaultModel: ModelID

        public init(models: [Entry], defaultModel: ModelID) {
            self.models = models
            self.defaultModel = defaultModel
        }
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
        /// Nil for the server's default model.
        public var model: ModelID?

        public init(instructions: String? = nil, model: ModelID? = nil) {
            self.instructions = instructions
            self.model = model
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
        /// Nil to use the parent's model.
        public var model: ModelID?

        public init(sessionID: SessionID, kind: SessionInfo.Kind = .fork, model: ModelID? = nil) {
            self.sessionID = sessionID
            self.kind = kind
            self.model = model
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
        /// The model's quota after the turn, for metered models.
        public var quota: QuotaStatus?

        public init(text: String, usage: TokenUsage, quota: QuotaStatus? = nil) {
            self.text = text
            self.usage = usage
            self.quota = quota
        }
    }
}

/// Moves a session to another model. Its history carries over, so the conversation continues.
public enum SetSessionModel: RPCMethod {
    public static let name = "session.setModel"

    public struct Params: Codable, Sendable {
        public var sessionID: SessionID
        public var model: ModelID

        public init(sessionID: SessionID, model: ModelID) {
            self.sessionID = sessionID
            self.model = model
        }
    }

    public typealias Result = SessionInfo
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
