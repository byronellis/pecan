import Foundation

/// A simple thread-safe circuit breaker to track provider health and enforce cooldown periods.
public actor CircuitBreaker {
    public static let shared = CircuitBreaker()

    private var failCounts: [String: Int] = [:]
    private var cooldownUntil: [String: Date] = [:]

    private init() {}

    /// Checks if a provider is currently allowed to receive requests.
    /// If the cooldown period has expired, it resets the failure count and returns true.
    public func isAvailable(providerID: String) -> Bool {
        if let until = cooldownUntil[providerID] {
            if Date() < until {
                return false // Cooled down / blocked
            } else {
                // Cooldown expired
                cooldownUntil.removeValue(forKey: providerID)
                failCounts[providerID] = 0
            }
        }
        return true
    }

    /// Records a successful request, resetting the failure counter.
    public func recordSuccess(providerID: String) {
        failCounts[providerID] = 0
        cooldownUntil.removeValue(forKey: providerID)
    }

    /// Records a failed request. If consecutive failures reach the threshold, triggers cooldown.
    public func recordFailure(providerID: String, threshold: Int, cooldownSeconds: Int) {
        let count = (failCounts[providerID] ?? 0) + 1
        failCounts[providerID] = count
        if count >= threshold {
            cooldownUntil[providerID] = Date().addingTimeInterval(TimeInterval(cooldownSeconds))
        }
    }
}
