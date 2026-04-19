import Foundation
import PecanShared

/// Manages the lifecycle of subagent sessions spawned by `RunAgentTool`.
///
/// Configured with the shared gRPC sink at startup (same pattern as `TaskClient`).
/// Subagents run as independent Swift Tasks and return a final summary string.
public actor SubagentPool {
    public static let shared = SubagentPool()

    private var sink: (any AgentEventSink)?

    public init() {}

    /// Provide the gRPC sink. Call this once from `main.swift` after the writer is created.
    public func configure(sink: any AgentEventSink) {
        self.sink = sink
    }

    /// Spawn a subagent and wait for it to complete, returning its final response.
    ///
    /// - Parameters:
    ///   - task: The task description given to the subagent.
    ///   - personaName: Optional persona to use. If provided and the persona exists,
    ///     that role's prompt is used; otherwise falls back to `CodingRole`.
    ///   - toolTags: Tool categories the subagent may use. Defaults to `["core", "web", "skills"]`.
    public func spawn(
        task: String,
        personaName: String? = nil,
        toolTags: Set<String>? = nil
    ) async throws -> String {
        guard let sink = sink else {
            throw NSError(
                domain: "SubagentPool", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "SubagentPool has no sink — call configure(sink:) at startup"]
            )
        }

        // Resolve persona: named override or CodingPersona fallback
        let persona: any AgentPersona
        if let personaName = personaName,
           let named = await PersonaManager.shared.persona(named: personaName) {
            persona = named
        } else {
            persona = CodingPersona()
        }

        // Build context from the current session state
        let projectInfo = await PromptComposer.shared.getProjectInfo()
        let teamInfo    = await PromptComposer.shared.getTeamInfo()

        // Subagents don't see the personas catalog (no sub-subagent spawning yet)
        let context = PromptContext(
            activeToolTags: toolTags ?? ["core", "web", "skills"],
            focusedTask: nil,
            agentID: "subagent",
            sessionID: "subagent",
            project: projectInfo,
            team: teamInfo,
            skillsCatalog: [],
            projectTools: await ToolManager.shared.allToolDescriptions(tags: ["project"]).map { PromptContext.ToolEntry(name: $0.name, description: $0.description) },
            personasCatalog: []
        )

        let systemPrompt = persona.render(context: context)
        let resolvedToolTags = toolTags ?? ["core", "web", "skills"]

        let session = SubagentSession(
            sink: sink,
            toolManager: .shared,
            toolTags: resolvedToolTags
        )

        return try await session.run(task: task, systemPrompt: systemPrompt)
    }
}
