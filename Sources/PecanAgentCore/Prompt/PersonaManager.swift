import Foundation
import PecanSettings

/// Registry of named personas/agents the agent can adopt temporarily or delegate to.
public actor PersonaManager {
    public static let shared = PersonaManager()

    private var builtInPersonas: [String: any AgentPersona] = [:]

    public init() {
        let planning = PlanningPersona()
        builtInPersonas[planning.personaName] = planning
        let coordinator = CoordinatorPersona()
        builtInPersonas[coordinator.personaName] = coordinator
    }

    /// All active (enabled) personas as (name, description) pairs, sorted by name.
    public func catalog() async -> [(name: String, description: String)] {
        // 1. Get enabled agents from DB
        let dbAgents = (try? await SettingsStore.shared.allAgents()) ?? []
        let dbAgentsMap = Dictionary(uniqueKeysWithValues: dbAgents.map { ($0.id, $0) })

        var list: [(name: String, description: String)] = []

        // 2. Add built-in personas if they are enabled
        for (name, persona) in builtInPersonas {
            if let dbAgent = dbAgentsMap[name] {
                if dbAgent.enabled {
                    list.append((name: name, description: dbAgent.description.isEmpty ? persona.description : dbAgent.description))
                }
            } else {
                list.append((name: name, description: persona.description))
            }
        }

        // Add coding/general base persona description if general is enabled
        if let generalAgent = dbAgentsMap["general"] {
            if generalAgent.enabled {
                list.append((name: "general", description: generalAgent.description))
            }
        } else {
            list.append((name: "general", description: "General-purpose coding agent with file, shell, and web tools."))
        }

        // 3. Add custom agents from DB
        for dbAgent in dbAgents where dbAgent.enabled {
            if dbAgent.id != "general" && builtInPersonas[dbAgent.id] == nil {
                list.append((name: dbAgent.id, description: dbAgent.description))
            }
        }

        return list.sorted { $0.name < $1.name }
    }

    /// Look up a persona by name.
    public func persona(named name: String) async -> (any AgentPersona)? {
        let dbAgent = try? await SettingsStore.shared.agent(id: name)
        
        // If present in DB but disabled, it cannot be resolved
        if let dbAgent, !dbAgent.enabled {
            return nil
        }

        // If it's a built-in persona, return it (applying DB prompt override if present)
        if let builtIn = builtInPersonas[name] {
            if let dbAgent, !dbAgent.systemPrompt.isEmpty {
                return CustomAgentPersona(
                    id: name,
                    description: dbAgent.description,
                    systemPrompt: dbAgent.systemPrompt,
                    allowedToolTags: Set(dbAgent.allowedToolTags)
                )
            }
            return builtIn
        }

        // If it is the general/coding persona
        if name == "general" {
            if let dbAgent, !dbAgent.systemPrompt.isEmpty {
                return CustomAgentPersona(
                    id: name,
                    description: dbAgent.description,
                    systemPrompt: dbAgent.systemPrompt,
                    allowedToolTags: Set(dbAgent.allowedToolTags)
                )
            }
            return CodingPersona()
        }

        // Otherwise check custom db agents
        if let dbAgent {
            return CustomAgentPersona(
                id: name,
                description: dbAgent.description,
                systemPrompt: dbAgent.systemPrompt,
                allowedToolTags: Set(dbAgent.allowedToolTags)
            )
        }

        return nil
    }

    /// Register an additional persona (e.g., from a Lua plugin).
    public func register(_ persona: any AgentPersona) {
        builtInPersonas[persona.personaName] = persona
    }
}

// MARK: - CustomAgentPersona

public struct CustomAgentPersona: SubagentPersona {
    public let personaName: String
    public let description: String
    private let systemPrompt: String
    public let allowedToolTags: Set<String>

    public init(id: String, description: String, systemPrompt: String, allowedToolTags: Set<String>) {
        self.personaName = id
        self.description = description
        self.systemPrompt = systemPrompt
        self.allowedToolTags = allowedToolTags
    }

    @PromptBuilder
    public func buildPrompt(context: PromptContext) -> any PromptNode {
        Raw(systemPrompt)
    }

    @PromptBuilder
    public func buildTaskPrompt(task: String, context: PromptContext) -> any PromptNode {
        Raw(task)
    }
}
