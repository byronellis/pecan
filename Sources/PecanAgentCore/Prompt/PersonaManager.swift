import Foundation

/// Registry of named personas the agent can adopt temporarily.
///
/// Built-in personas are registered at init time; additional personas (e.g. from Lua
/// plugins) can be added via `register(_:)`.
public actor PersonaManager {
    public static let shared = PersonaManager()

    private var personas: [String: any AgentPersona] = [:]

    public init() {
        let planning = PlanningPersona()
        personas[planning.personaName] = planning
    }

    /// All registered personas as (name, description) pairs, sorted by name.
    public func catalog() -> [(name: String, description: String)] {
        personas.map { (name: $0.key, description: $0.value.description) }
            .sorted { $0.name < $1.name }
    }

    /// Look up a persona by name.
    public func persona(named name: String) -> (any AgentPersona)? {
        personas[name]
    }

    /// Register an additional persona (e.g., from a Lua plugin).
    public func register(_ persona: any AgentPersona) {
        personas[persona.personaName] = persona
    }
}
