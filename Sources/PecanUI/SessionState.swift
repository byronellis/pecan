import Foundation
import ANSITerminal

actor SessionState {
    private var sessionOrder: [String] = []
    private var sessions: [String: LocalSession] = [:]
    private var activeSessionID: String?
    private var focusedTasks: [String: String] = [:]
    private var outputBuffers: [String: [String]] = [:]
    private var unreadCounts: [String: Int] = [:]
    /// Remembers last-active agent per team so Alt+t restores context.
    private var lastActiveByTeam: [String: String] = [:]
    private let maxBufferEntries = 1000

    // MARK: - Session registration

    func addSession(id: String, name: String, projectName: String = "", teamName: String = "", agentNumber: Int32 = 0) {
        let session = LocalSession(id: id, name: name, projectName: projectName, teamName: teamName, agentNumber: agentNumber)
        sessions[id] = session
        if !sessionOrder.contains(id) {
            sessionOrder.append(id)
        }
        activeSessionID = id
        lastActiveByTeam[normalizedTeam(teamName)] = id
    }

    func registerSession(id: String, name: String, projectName: String = "", teamName: String = "", agentNumber: Int32 = 0) {
        if sessions[id] != nil { return }
        let session = LocalSession(id: id, name: name, projectName: projectName, teamName: teamName, agentNumber: agentNumber)
        sessions[id] = session
        sessionOrder.append(id)
    }

    func updateAgentNumber(sessionID: String, agentNumber: Int32) async {
        await sessions[sessionID]?.setAgentNumber(agentNumber)
    }

    private func normalizedTeam(_ teamName: String) -> String {
        (teamName.isEmpty || teamName == "default") ? "" : teamName
    }

    // MARK: - Active session

    func setActive(_ id: String) async {
        guard let session = sessions[id] else { return }
        activeSessionID = id
        let team = await session.getTeamName()
        lastActiveByTeam[normalizedTeam(team)] = id
    }

    func setActiveByName(_ name: String) async -> Bool {
        for (id, session) in sessions {
            let sName = await session.getName()
            if sName == name {
                await setActive(id)
                return true
            }
        }
        return false
    }

    func getActiveID() -> String? { activeSessionID }
    func getActiveSession() -> LocalSession? {
        guard let id = activeSessionID else { return nil }
        return sessions[id]
    }
    
    func getActiveName() async -> String? {
        guard let id = activeSessionID, let s = sessions[id] else { return nil }
        return await s.getName()
    }

    func getActiveProjectName() async -> String? {
        guard let id = activeSessionID, let s = sessions[id] else { return nil }
        let p = await s.getProjectName()
        return p.isEmpty ? nil : p
    }

    func getActiveTeamName() async -> String? {
        guard let id = activeSessionID, let s = sessions[id] else { return nil }
        let t = await s.getTeamName()
        let norm = normalizedTeam(t)
        return norm.isEmpty ? nil : norm
    }

    func isActiveSession(_ sessionID: String) -> Bool { sessionID == activeSessionID }

    func updateProjectTeam(sessionID: String, projectName: String, teamName: String) async {
        guard let session = sessions[sessionID] else { return }
        await session.setProjectName(projectName)
        await session.setTeamName(teamName)
    }

    func allSessions() -> [LocalSession] {
        sessionOrder.compactMap { sessions[$0] }
    }

    // MARK: - Agent tab list

    func agentTabList() async -> [AgentTabInfo] {
        var tabs: [AgentTabInfo] = []
        for id in sessionOrder {
            guard let s = sessions[id] else { continue }
            let name = await s.getName()
            let team = await s.getTeamName()
            let number = await s.getAgentNumber()
            tabs.append(AgentTabInfo(
                id: s.id,
                name: name,
                teamKey: normalizedTeam(team),
                isActive: s.id == activeSessionID,
                hasUnread: (unreadCounts[id] ?? 0) > 0,
                agentNumber: number
            ))
        }
        return tabs.sorted { $0.agentNumber < $1.agentNumber }
    }

    // MARK: - Team list (for team picker)

    func teamList() async -> [(key: String, displayName: String)] {
        var seen: [String] = []
        var result: [(key: String, displayName: String)] = []
        
        var hasNoTeam = false
        for id in sessionOrder {
            if let s = sessions[id] {
                let team = await s.getTeamName()
                if normalizedTeam(team) == "" {
                    hasNoTeam = true
                    break
                }
            }
        }
        
        if hasNoTeam {
            result.append((key: "", displayName: "(no team)"))
            seen.append("")
        }
        for id in sessionOrder {
            guard let s = sessions[id] else { continue }
            let team = await s.getTeamName()
            let key = normalizedTeam(team)
            if !key.isEmpty && !seen.contains(key) {
                seen.append(key)
                result.append((key: key, displayName: key))
            }
        }
        return result
    }

    // MARK: - Within-team navigation

    func activeTeamKey() async -> String {
        guard let id = activeSessionID, let s = sessions[id] else { return "" }
        let team = await s.getTeamName()
        return normalizedTeam(team)
    }

    private func agentsInTeam(_ teamKey: String) async -> [String] {
        var list: [String] = []
        for id in sessionOrder {
            if let s = sessions[id] {
                let team = await s.getTeamName()
                if normalizedTeam(team) == teamKey {
                    list.append(id)
                }
            }
        }
        return list
    }

    func nextAgentInTeam() async -> String? {
        let key = await activeTeamKey()
        let members = await agentsInTeam(key)
        guard members.count > 1 else { return nil }
        let idx = members.firstIndex(of: activeSessionID ?? "") ?? -1
        return members[(idx + 1) % members.count]
    }

    func prevAgentInTeam() async -> String? {
        let key = await activeTeamKey()
        let members = await agentsInTeam(key)
        guard members.count > 1 else { return nil }
        let idx = members.firstIndex(of: activeSessionID ?? "") ?? 0
        return members[(idx - 1 + members.count) % members.count]
    }

    /// 0-indexed within the active team.
    func agentByIndexInTeam(_ index: Int) async -> String? {
        let key = await activeTeamKey()
        let members = await agentsInTeam(key)
        guard index >= 0, index < members.count else { return nil }
        return members[index]
    }

    /// Look up an agent in the active team by its assigned agent number.
    func agentByNumber(_ number: Int32) async -> String? {
        let teamKey = await activeTeamKey()
        for s in sessions.values {
            let team = await s.getTeamName()
            let num = await s.getAgentNumber()
            if normalizedTeam(team) == teamKey && num == number {
                return s.id
            }
        }
        return nil
    }

    // MARK: - Team switching

    /// Returns the best agent to activate when switching to a team:
    /// last-active agent in that team, or its first agent.
    func agentForTeam(_ teamKey: String) async -> String? {
        if let last = lastActiveByTeam[teamKey], sessions[last] != nil { return last }
        let members = await agentsInTeam(teamKey)
        return members.first
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

    // MARK: - Session removal

    func removeSession(id: String) {
        sessions.removeValue(forKey: id)
        sessionOrder.removeAll { $0 == id }
        focusedTasks.removeValue(forKey: id)
        outputBuffers.removeValue(forKey: id)
        unreadCounts.removeValue(forKey: id)
        if activeSessionID == id {
            activeSessionID = sessionOrder.first
        }
    }

    func getName(for id: String) async -> String? {
        guard let s = sessions[id] else { return nil }
        return await s.getName()
    }
}
