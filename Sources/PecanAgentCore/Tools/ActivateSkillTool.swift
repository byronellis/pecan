import Foundation

public struct ActivateSkillTool: PecanTool, Sendable {
    public let name = "activate_skill"
    public let tags: Set<String> = ["skills"]
    public let description = "Load a skill's full instructions into context. Use when a task matches a skill's description from the catalog."
    public let parametersJSONSchema = """
    {
        "type": "object",
        "properties": {
            "name": { "type": "string", "description": "The name of the skill to activate, as shown in the skill catalog." }
        },
        "required": ["name"]
    }
    """

    public func execute(argumentsJSON: String) async throws -> String {
        let args = try parseArguments(argumentsJSON)
        guard let skillName = args["name"] as? String else {
            throw ToolError.invalidArguments("Missing required parameter: name")
        }

        guard let result = await SkillManager.shared.activate(name: skillName) else {
            throw ToolError.invalidArguments("Skill '\(skillName)' not found. Use the skill catalog to see available skills.")
        }

        return result
    }

    public func formatResult(_ result: String) -> String? {
        // Extract skill name from the XML tag
        if let range = result.range(of: "name=\""),
           let endRange = result[range.upperBound...].range(of: "\"") {
            let name = result[range.upperBound..<endRange.lowerBound]
            return "Activated skill: \(name)"
        }
        return "Skill activated"
    }
}
