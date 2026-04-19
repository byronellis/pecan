import Foundation

// MARK: - EnterPersonaTool

public struct EnterPersonaTool: PecanTool, Sendable {
    public let name = "enter_persona"
    public let description = """
        Switch to a named persona for the current task. \
        The persona replaces your system prompt with behaviour tailored to that mode \
        (e.g. 'planning' focuses on analysis before implementation). \
        Use leave_persona to return to the coding role when done.
        """
    public let tags: Set<String> = ["meta"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "name": {
                "type": "string",
                "description": "Persona to activate, e.g. 'planning'."
            }
        },
        "required": ["name"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let personaName = args["name"] as? String, !personaName.isEmpty else {
            throw ToolError.invalidArguments("Missing required parameter: name")
        }

        guard await PersonaManager.shared.persona(named: personaName) != nil else {
            let available = await PersonaManager.shared.catalog().map { $0.name }.joined(separator: ", ")
            throw ToolError.executionFailed("Persona '\(personaName)' not found. Available: \(available)")
        }

        // AgentEventHandler detects this tool name and applies the side effect
        // (updating PromptComposer + replacing the server-side system prompt).
        return "entered:\(personaName)"
    }
}

// MARK: - LeavePersonaTool

public struct LeavePersonaTool: PecanTool, Sendable {
    public let name = "leave_persona"
    public let description = "Return to the base coding role, discarding the active persona."
    public let tags: Set<String> = ["meta"]
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {},
        "required": []
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        // AgentEventHandler detects this tool name and applies the side effect.
        return "left_persona"
    }
}
