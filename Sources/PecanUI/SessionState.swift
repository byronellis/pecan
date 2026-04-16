import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ANSITerminal
import GRPC
import NIO
import PecanShared

actor SessionState {
    struct Session {
        let id: String
        let name: String
        var projectName: String
        var teamName: String
    }

    private var sessionOrder: [String] = []
    private var sessions: [String: Session] = [:]
    private var activeSessionID: String?
    private var focusedTasks: [String: String] = [:]
    private var outputBuffers: [String: [String]] = [:]
    private var unreadCounts: [String: Int] = [:]
    /// Remembers last-active agent per team so Alt+t restores context.
    private var lastActiveByTeam: [String: String] = [:]
    private let maxBufferEntries = 1000

    // MARK: - Session registration

    func addSession(id: String, name: String, projectName: String = "", teamName: String = "") {
        sessions[id] = Session(id: id, name: name, projectName: projectName, teamName: teamName)
        if !sessionOrder.contains(id) {
            sessionOrder.append(id)
        }
        activeSessionID = id
        lastActiveByTeam[normalizedTeam(teamName)] = id
    }

    /// Register a session without changing the active session — used to pre-populate known sessions.
    func registerSession(id: String, name: String, projectName: String = "", teamName: String = "") {
        if sessions[id] != nil { return }  // already known
        sessions[id] = Session(id: id, name: name, projectName: projectName, teamName: teamName)
        sessionOrder.append(id)
    }

    private func normalizedTeam(_ teamName: String) -> String {
        (teamName.isEmpty || teamName == "default") ? "" : teamName
    }

    // MARK: - Active session

    func setActive(_ id: String) {
        guard sessions[id] != nil else { return }
        activeSessionID = id
        // Remember as last-active for this team
        if let s = sessions[id] {
            lastActiveByTeam[normalizedTeam(s.teamName)] = id
        }
    }

    func setActiveByName(_ name: String) -> Bool {
        guard let session = sessions.values.first(where: { $0.name == name }) else { return false }
        setActive(session.id)
        return true
    }

    func getActiveID() -> String? { activeSessionID }
    func getActiveName() -> String? {
        guard let id = activeSessionID else { return nil }
        return sessions[id]?.name
    }

    func getActiveProjectName() -> String? {
        guard let id = activeSessionID, let s = sessions[id] else { return nil }
        return s.projectName.isEmpty ? nil : s.projectName
    }

    func getActiveTeamName() -> String? {
        guard let id = activeSessionID, let s = sessions[id] else { return nil }
        let t = normalizedTeam(s.teamName)
        return t.isEmpty ? nil : t
    }

    func isActiveSession(_ sessionID: String) -> Bool { sessionID == activeSessionID }

    func updateProjectTeam(sessionID: String, projectName: String, teamName: String) {
        guard var session = sessions[sessionID] else { return }
        session.projectName = projectName
        session.teamName = teamName
        sessions[sessionID] = session
    }

    func allSessions() -> [Session] {
        sessionOrder.compactMap { sessions[$0] }
    }

    // MARK: - Agent tab list

    func agentTabList() -> [AgentTabInfo] {
        sessionOrder.compactMap { id in
            guard let s = sessions[id] else { return nil }
            return AgentTabInfo(
                id: s.id,
                name: s.name,
                teamKey: normalizedTeam(s.teamName),
                isActive: s.id == activeSessionID,
                hasUnread: (unreadCounts[id] ?? 0) > 0
            )
        }
    }

    /// Legacy — returns flat (name, isActive) list.
    func agentList() -> [(name: String, isActive: Bool)] {
        agentTabList().map { ($0.name, $0.isActive) }
    }

    // MARK: - Team list (for team picker)

    func teamList() -> [(key: String, displayName: String)] {
        var seen: [String] = []
        var result: [(key: String, displayName: String)] = []
        let hasNoTeam = sessionOrder.compactMap { sessions[$0] }.contains { normalizedTeam($0.teamName) == "" }
        if hasNoTeam {
            result.append((key: "", displayName: "(no team)"))
            seen.append("")
        }
        for id in sessionOrder {
            guard let s = sessions[id] else { continue }
            let key = normalizedTeam(s.teamName)
            if !key.isEmpty && !seen.contains(key) {
                seen.append(key)
                result.append((key: key, displayName: key))
            }
        }
        return result
    }

    // MARK: - Within-team navigation

    func activeTeamKey() -> String {
        guard let id = activeSessionID, let s = sessions[id] else { return "" }
        return normalizedTeam(s.teamName)
    }

    private func agentsInTeam(_ teamKey: String) -> [String] {
        sessionOrder.filter { id in
            guard let s = sessions[id] else { return false }
            return normalizedTeam(s.teamName) == teamKey
        }
    }

    func nextAgentInTeam() -> String? {
        let members = agentsInTeam(activeTeamKey())
        guard members.count > 1 else { return nil }
        let idx = members.firstIndex(of: activeSessionID ?? "") ?? -1
        return members[(idx + 1) % members.count]
    }

    func prevAgentInTeam() -> String? {
        let members = agentsInTeam(activeTeamKey())
        guard members.count > 1 else { return nil }
        let idx = members.firstIndex(of: activeSessionID ?? "") ?? 0
        return members[(idx - 1 + members.count) % members.count]
    }

    /// 0-indexed within the active team.
    func agentByIndexInTeam(_ index: Int) -> String? {
        let members = agentsInTeam(activeTeamKey())
        guard index >= 0, index < members.count else { return nil }
        return members[index]
    }

    // MARK: - Team switching

    /// Returns the best agent to activate when switching to a team:
    /// last-active agent in that team, or its first agent.
    func agentForTeam(_ teamKey: String) -> String? {
        if let last = lastActiveByTeam[teamKey], sessions[last] != nil { return last }
        return agentsInTeam(teamKey).first
    }

    // MARK: - Focused tasks

    func setFocusedTask(sessionID: String, title: String) {
        if title.isEmpty { focusedTasks.removeValue(forKey: sessionID) }
        else { focusedTasks[sessionID] = title }
    }

    func getActiveFocusedTask() -> String? {
        guard let id = activeSessionID else { return nil }
        return focusedTasks[id]
    }

    // MARK: - Output buffering + unread

    func bufferOutput(_ sessionID: String, rawText: String) {
        if outputBuffers[sessionID] == nil { outputBuffers[sessionID] = [] }
        outputBuffers[sessionID]!.append(rawText)
        if outputBuffers[sessionID]!.count > maxBufferEntries {
            outputBuffers[sessionID]!.removeFirst(outputBuffers[sessionID]!.count - maxBufferEntries)
        }
        unreadCounts[sessionID, default: 0] += 1
    }

    func drainBuffer(_ sessionID: String) -> [String] {
        unreadCounts.removeValue(forKey: sessionID)
        return outputBuffers.removeValue(forKey: sessionID) ?? []
    }

    // MARK: - Legacy compat

    func setSession(id: String, name: String) { addSession(id: id, name: name) }
    func getID() -> String? { activeSessionID }
    func getAgentName() -> String? { getActiveName() }
}
