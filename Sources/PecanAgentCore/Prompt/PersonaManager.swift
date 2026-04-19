import Foundation

/// Registry of named personas the agent can adopt temporarily.
///
/// A persona is a full `AgentRole` that replaces the base role for the duration of a task.
/// The built-in personas are registered at init time; Lua user personas (future) can be
/// added via `register(_:)`.
public actor PersonaManager {
    public static let shared = PersonaManager()

    private var personas: [String: any AgentRole] = [:]

    public init() {
        personas[PlanningPersona().roleName] = PlanningPersona()
    }

    /// All registered personas as (name, description) pairs, sorted by name.
    public func catalog() -> [(name: String, description: String)] {
        personas.map { (name: $0.key, description: $0.value.description) }
            .sorted { $0.name < $1.name }
    }

    /// Look up a persona by its role name.
    public func persona(named name: String) -> (any AgentRole)? {
        personas[name]
    }

    /// Register an additional persona (e.g., from a Lua plugin).
    public func register(_ role: any AgentRole) {
        personas[role.roleName] = role
    }
}
