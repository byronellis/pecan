import Foundation
import PecanSettings

/// Manages the lifecycle of subagent sessions spawned by `RunAgentTool`.
///
/// Subagents run as independent Swift Tasks and return a final summary string.
public actor SubagentPool {
    public static let shared = SubagentPool()

    public init() {}

    /// Spawn a subagent and wait for it to complete, returning its final response.
    ///
    /// - Parameters:
    ///   - task: The task description given to the subagent.
    ///   - personaName: Optional persona to use. If provided and the persona exists,
    ///     that role's prompt is used; otherwise falls back to `CodingPersona`.
    ///   - toolTags: Tool categories the subagent may use. If omitted, `SubagentPersona.allowedToolTags`
    ///     is used when applicable, otherwise defaults to `["core", "web", "skills"]`.
    public func spawn(
        task: String,
        personaName: String? = nil,
        toolTags: Set<String>? = nil
    ) async throws -> String {
        // Resolve persona: named override or CodingPersona fallback
        let persona: any AgentPersona
        if let personaName = personaName,
           let named = await PersonaManager.shared.persona(named: personaName) {
            persona = named
        } else {
            persona = CodingPersona()
        }

        // Resolve tool tags: explicit > SubagentPersona default > generic fallback
        // Strip "meta" unconditionally — run_agent / enter_persona / leave_persona must
        // never be available to subagents, regardless of what a persona declares.
        let resolvedToolTags: Set<String>
        if let toolTags = toolTags {
            resolvedToolTags = toolTags.subtracting(["meta"])
        } else if let subPersona = persona as? SubagentPersona {
            resolvedToolTags = subPersona.allowedToolTags.subtracting(["meta"])
        } else {
            resolvedToolTags = ["core", "web", "skills"]
        }

        // Resolve subagent model override from database if enabled
        let resolvedModel: String?
        if let agentConfig = try? await SettingsStore.shared.agent(id: persona.personaName), agentConfig.enabled {
            resolvedModel = agentConfig.model
        } else {
            resolvedModel = nil
        }

        // Create the session first to get its unique agentID for the context
        let session = SubagentSession(
            toolManager: .shared,
            toolTags: resolvedToolTags,
            model: resolvedModel
        )
        let agentID = session.agentID

        // Build context from the current session state
        let projectInfo = await PromptComposer.shared.getProjectInfo()
        let teamInfo    = await PromptComposer.shared.getTeamInfo()

        // Subagents don't see the personas catalog (no sub-subagent spawning yet)
        let context = PromptContext(
            activeToolTags: resolvedToolTags,
            focusedTask: nil,
            agentID: agentID,
            sessionID: agentID,
            project: projectInfo,
            team: teamInfo,
            skillsCatalog: [],
            projectTools: await ToolManager.shared.allToolDescriptions(tags: ["project"]).map { PromptContext.ToolEntry(name: $0.name, description: $0.description) },
            personasCatalog: []
        )

        let systemPrompt = persona.render(context: context)

        // SubagentPersona can render a richer task-scoped initial message
        let initialMessage: String
        if let subPersona = persona as? SubagentPersona {
            initialMessage = subPersona.buildTaskPrompt(task: task, context: context).render()
        } else {
            initialMessage = task
        }

        return try await session.run(task: initialMessage, systemPrompt: systemPrompt)
    }
}
