import Foundation

/// A simple thread-safe budget tracker to enforce daily spend limits per provider.
public actor BudgetLimiter {
    public static let shared = BudgetLimiter()

    private var dailySpend: [String: Double] = [:]
    private var lastResetDate = Date()

    private init() {}

    private func checkReset() {
        let now = Date()
        let cal = Calendar.current
        if !cal.isDate(now, inSameDayAs: lastResetDate) {
            dailySpend.removeAll()
            lastResetDate = now
        }
    }

    /// Checks if a provider has remaining budget.
    public func isWithinBudget(providerID: String, dailyLimitUSD: Double) -> Bool {
        checkReset()
        let current = dailySpend[providerID] ?? 0.0
        return current < dailyLimitUSD
    }

    /// Records tokens used for a request and adds to the provider's daily spend.
    public func recordUsage(providerID: String, providerType: String, promptTokens: Int, completionTokens: Int) {
        checkReset()
        
        let inRate: Double // cost per token
        let outRate: Double // cost per token

        switch providerType.lowercased() {
        case "mlx", "huggingface":
            inRate = 0.0
            outRate = 0.0
        case "fireworks":
            inRate = 0.20 / 1_000_000.0
            outRate = 0.80 / 1_000_000.0
        default:
            // Custom or openai fallback rates
            inRate = 1.00 / 1_000_000.0
            outRate = 2.00 / 1_000_000.0
        }

        let cost = (Double(promptTokens) * inRate) + (Double(completionTokens) * outRate)
        dailySpend[providerID, default: 0.0] += cost
    }
}
