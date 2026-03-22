import Foundation
import Lua

/// Discovers, catalogs, and activates Agent Skills per the agentskills.io standard.
/// Skills are folders containing a SKILL.md file with YAML frontmatter (name, description)
/// and optional scripts/, references/, and assets/ directories.
public actor SkillManager {
    public static let shared = SkillManager()

    struct SkillInfo: Sendable {
        let name: String
        let description: String
        let location: String      // absolute path to SKILL.md
        let baseDirectory: String  // parent of SKILL.md
    }

    private var skills: [String: SkillInfo] = [:]
    private var activatedSkills: Set<String> = []

    /// Scan known paths for SKILL.md files and build the catalog.
    public func discoverSkills() {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.path

        let searchPaths = [
            "/skills",                        // container mount (server copies ~/.pecan/skills here)
            "\(homeDir)/.pecan/skills",       // fallback for local process spawner
            "\(homeDir)/.agents/skills",
        ]

        for basePath in searchPaths {
            guard fm.fileExists(atPath: basePath) else { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: basePath) else { continue }

            for entry in entries {
                let skillDir = "\(basePath)/\(entry)"
                let skillFile = "\(skillDir)/SKILL.md"
                guard fm.fileExists(atPath: skillFile) else { continue }
                guard let content = try? String(contentsOfFile: skillFile, encoding: .utf8) else { continue }

                guard let (name, description) = parseFrontmatter(content) else {
                    print("[SkillManager] Skipping \(skillFile): missing or invalid YAML frontmatter")
                    continue
                }

                let info = SkillInfo(
                    name: name,
                    description: description,
                    location: skillFile,
                    baseDirectory: skillDir
                )
                skills[name] = info
            }
        }

        if !skills.isEmpty {
            print("[SkillManager] Discovered \(skills.count) skill(s): \(skills.keys.sorted().joined(separator: ", "))")
        }
    }

    /// Return the catalog of all discovered skills.
    public func catalog() -> [(name: String, description: String)] {
        skills.values
            .map { (name: $0.name, description: $0.description) }
            .sorted { $0.name < $1.name }
    }

    /// Activate a skill: return its full SKILL.md body and resource listing.
    public func activate(name: String) -> String? {
        guard let skill = skills[name] else { return nil }
        activatedSkills.insert(name)

        guard let content = try? String(contentsOfFile: skill.location, encoding: .utf8) else { return nil }

        // Strip frontmatter to get the body
        let body = stripFrontmatter(content)

        var result = "<skill_content name=\"\(name)\">\n\(body)\n</skill_content>"

        // List resources in the skill directory
        let resources = listResources(skill.baseDirectory)
        if !resources.isEmpty {
            result += "\n<skill_resources name=\"\(name)\">\n"
            for resource in resources {
                result += "  \(resource)\n"
            }
            result += "</skill_resources>"
        }

        return result
    }

    /// Scan skill scripts/ directories for module-pattern Lua tools and register them.
    public func registerLuaTools() async {
        let fm = FileManager.default

        for (skillName, skill) in skills {
            let scriptsDir = "\(skill.baseDirectory)/scripts"
            guard fm.fileExists(atPath: scriptsDir) else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: scriptsDir) else { continue }

            for file in files where file.hasSuffix(".lua") {
                let luaPath = "\(scriptsDir)/\(file)"
                guard let script = try? String(contentsOfFile: luaPath, encoding: .utf8) else { continue }

                let baseName = (file as NSString).deletingPathExtension
                guard let moduleInfo = detectLuaModule(script: script, fallbackName: baseName) else { continue }

                let toolName = moduleInfo.name ?? baseName
                let toolDesc = moduleInfo.description ?? "A Lua tool from skill '\(skillName)'."
                let toolSchema = moduleInfo.schema ?? "{\"type\":\"object\",\"properties\":{}}"

                let tool = LuaTool(
                    name: toolName,
                    description: toolDesc,
                    parametersJSONSchema: toolSchema,
                    mode: .module(script: script)
                )
                await ToolManager.shared.register(tool: tool)
                print("[SkillManager] Registered Lua tool '\(toolName)' from skill '\(skillName)'")
            }
        }
    }

    // MARK: - Private Helpers

    /// Parse YAML frontmatter delimited by --- lines. Extract name and description.
    private func parseFrontmatter(_ content: String) -> (name: String, description: String)? {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        var name: String?
        var description: String?

        for i in 1..<lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }

            if let value = extractYAMLValue(line: line, key: "name") {
                name = value
            } else if let value = extractYAMLValue(line: line, key: "description") {
                description = value
            }
        }

        guard let name, let description else { return nil }
        return (name, description)
    }

    /// Extract a value from a simple "key: value" YAML line.
    /// Handles quoted and unquoted values leniently.
    private func extractYAMLValue(line: String, key: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = "\(key):"
        guard trimmed.hasPrefix(prefix) else { return nil }

        var value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)

        // Strip surrounding quotes if present
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }

        return value.isEmpty ? nil : value
    }

    /// Strip YAML frontmatter from content, returning just the body.
    private func stripFrontmatter(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return content }

        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                let bodyLines = Array(lines[(i + 1)...])
                return bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return content
    }

    /// List files in a skill directory, relative to the base.
    private func listResources(_ baseDirectory: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: baseDirectory) else { return [] }

        var resources: [String] = []
        while let path = enumerator.nextObject() as? String {
            // Skip SKILL.md itself and hidden files
            if path == "SKILL.md" || path.hasPrefix(".") { continue }
            // Only list files, not directories
            var isDir: ObjCBool = false
            let fullPath = "\(baseDirectory)/\(path)"
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue {
                resources.append(path)
            }
        }
        return resources.sorted()
    }

    /// Detect whether a Lua script returns a module table with an `execute` function.
    private struct LuaModuleInfo {
        var name: String?
        var description: String?
        var schema: String?
    }

    private func detectLuaModule(script: String, fallbackName: String) -> LuaModuleInfo? {
        let L = LuaState(libraries: .all)
        defer { L.close() }

        do {
            try L.load(string: script, name: fallbackName)
            try L.pcall(nargs: 0, nret: 1)
        } catch {
            return nil
        }

        guard L.type(-1) == .table else { return nil }

        L.push("execute")
        L.rawget(-2)
        let hasExecute = L.type(-1) == .function
        L.pop(1)
        guard hasExecute else { return nil }

        var info = LuaModuleInfo()

        L.push("name")
        L.rawget(-2)
        if let n = L.tostring(-1) { info.name = n }
        L.pop(1)

        L.push("description")
        L.rawget(-2)
        if let d = L.tostring(-1) { info.description = d }
        L.pop(1)

        L.push("schema")
        L.rawget(-2)
        if let s = L.tostring(-1) { info.schema = s }
        L.pop(1)

        return info
    }
}
