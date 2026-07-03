import Foundation

// MARK: - ModelRef

/// A reference to a specific (provider, model) pair.
public struct ModelRef: Codable, Sendable, Equatable {
    public var providerID: String
    public var modelID: String

    public var display: String { "\(providerID) / \(modelID)" }

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

// MARK: - RoutingStrategy

/// How pecan selects a provider/model for a request when no explicit override is given.
public enum RoutingStrategy: String, Codable, Sendable, CaseIterable {
    /// Always use the default provider/model. No selection logic applied.
    case simple = "simple"
    /// Prefer providers with lowest estimated cost ($/M tokens).
    case costBased = "cost_based"
    /// Prefer providers with lowest current latency (TTFT).
    case latencyBased = "latency_based"
    /// Use a judge/classifier LLM to route each request automatically.
    case automatic = "automatic"

    public var displayName: String {
        switch self {
        case .simple:      return "Simple (always use default)"
        case .costBased:   return "Cost-Based (prefer cheapest)"
        case .latencyBased:return "Latency-Based (prefer fastest)"
        case .automatic:   return "Automatic (judge model routes)"
        }
    }
}

// MARK: - ProviderBudget

/// Daily spend cap for a specific provider.
public struct ProviderBudget: Codable, Sendable {
    public var providerID: String
    public var dailyLimitUSD: Double

    public init(providerID: String, dailyLimitUSD: Double) {
        self.providerID = providerID
        self.dailyLimitUSD = dailyLimitUSD
    }
}

// MARK: - RoutingConfig

/// Complete routing configuration for the pecan proxy.
public struct RoutingConfig: Codable, Sendable {

    // ── Default Route ────────────────────────────────────────────────────────
    /// The primary model used when no rule overrides the choice.
    public var defaultRoute: ModelRef

    // ── Strategy ─────────────────────────────────────────────────────────────
    /// How to select among enabled providers.
    public var strategy: RoutingStrategy

    // ── Automatic / Judge Routing ─────────────────────────────────────────────
    /// Model used to classify the incoming prompt and decide which provider
    /// handles the request. Only active when strategy == .automatic.
    public var autoJudgeModel: ModelRef?

    // ── Fallback Chain ───────────────────────────────────────────────────────
    /// Ordered list of (provider, model) pairs tried when the primary fails.
    public var fallbackChain: [ModelRef]

    /// Fallback triggered when the primary cannot fit the request in its
    /// context window (context_window_exceeded error).
    public var contextWindowFallback: ModelRef?

    /// Fallback triggered when the primary refuses the request on content
    /// policy grounds.
    public var contentPolicyFallback: ModelRef?

    // ── Circuit Breaker ──────────────────────────────────────────────────────
    /// Enable automatic circuit-breaking when a provider fails repeatedly.
    public var circuitBreakerEnabled: Bool

    /// Number of consecutive failures before a provider is placed in cooldown.
    public var circuitBreakerFailThreshold: Int

    /// Seconds a failed provider is excluded from routing before re-trying.
    public var circuitBreakerCooldownSeconds: Int

    // ── Budget Limits ────────────────────────────────────────────────────────
    /// Enable per-provider daily spend limits.
    public var budgetEnabled: Bool

    /// Per-provider daily caps. Requests to providers over budget are skipped.
    public var providerBudgets: [ProviderBudget]

    // ── Defaults constructor ─────────────────────────────────────────────────
    public init(
        defaultRoute: ModelRef = ModelRef(providerID: "", modelID: ""),
        strategy: RoutingStrategy = .simple,
        autoJudgeModel: ModelRef? = nil,
        fallbackChain: [ModelRef] = [],
        contextWindowFallback: ModelRef? = nil,
        contentPolicyFallback: ModelRef? = nil,
        circuitBreakerEnabled: Bool = false,
        circuitBreakerFailThreshold: Int = 3,
        circuitBreakerCooldownSeconds: Int = 60,
        budgetEnabled: Bool = false,
        providerBudgets: [ProviderBudget] = []
    ) {
        self.defaultRoute = defaultRoute
        self.strategy = strategy
        self.autoJudgeModel = autoJudgeModel
        self.fallbackChain = fallbackChain
        self.contextWindowFallback = contextWindowFallback
        self.contentPolicyFallback = contentPolicyFallback
        self.circuitBreakerEnabled = circuitBreakerEnabled
        self.circuitBreakerFailThreshold = circuitBreakerFailThreshold
        self.circuitBreakerCooldownSeconds = circuitBreakerCooldownSeconds
        self.budgetEnabled = budgetEnabled
        self.providerBudgets = providerBudgets
    }
}
