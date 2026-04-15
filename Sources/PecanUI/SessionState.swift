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

    /// Ordered list of sessions (insertion order)
    private var sessionOrder: [String] = []
    private var sessions: [String: Session] = [:]
    private var activeSessionID: String?
    /// sessionID -> focused task title
    private var focusedTasks: [String: String] = [:]
    /// Buffered raw output texts for non-active sessions (rendered on drain)
    private var outputBuffers: [String: [String]] = [:]
    /// Max buffered entries per session to prevent unbounded memory growth
    private let maxBufferEntries = 1000

    func addSession(id: String, name: String, projectName: String = "", teamName: String = "") {
        sessions[id] = Session(id: id, name: name, projectName: projectName, teamName: teamName)
        if !sessionOrder.contains(id) {
            sessionOrder.append(id)
        }
        activeSessionID = id
    }

    func getActiveProjectName() -> String? {
        guard let id = activeSessionID, let s = sessions[id] else { return nil }
        return s.projectName.isEmpty ? nil : s.projectName
    }

    func getActiveTeamName() -> String? {
        guard let id = activeSessionID, let s = sessions[id] else { return nil }
        // Hide "default" team
        if s.teamName.isEmpty || s.teamName == "default" { return nil }
        return s.teamName
    }

    func updateProjectTeam(sessionID: String, projectName: String, teamName: String) {
        guard var session = sessions[sessionID] else { return }
        session.projectName = projectName
        session.teamName = teamName
        sessions[sessionID] = session
    }

    func setActive(_ id: String) {
        if sessions[id] != nil {
            activeSessionID = id
        }
    }

    func setActiveByName(_ name: String) -> Bool {
        if let session = sessions.values.first(where: { $0.name == name }) {
            activeSessionID = session.id
            return true
        }
        return false
    }

    func getActiveID() -> String? {
        return activeSessionID
    }

    func getActiveName() -> String? {
        guard let id = activeSessionID else { return nil }
        return sessions[id]?.name
    }

    func allSessions() -> [Session] {
        return sessionOrder.compactMap { sessions[$0] }
    }

    func agentList() -> [(name: String, isActive: Bool)] {
        return sessionOrder.compactMap { id in
            guard let s = sessions[id] else { return nil }
            return (s.name, s.id == activeSessionID)
        }
    }

    func setFocusedTask(sessionID: String, title: String) {
        if title.isEmpty {
            focusedTasks.removeValue(forKey: sessionID)
        } else {
            focusedTasks[sessionID] = title
        }
    }

    func getActiveFocusedTask() -> String? {
        guard let id = activeSessionID else { return nil }
        return focusedTasks[id]
    }

    // Legacy compatibility
    func setSession(id: String, name: String) {
        addSession(id: id, name: name)
    }

    func getID() -> String? {
        return activeSessionID
    }

    func getAgentName() -> String? {
        guard let id = activeSessionID else { return nil }
        return sessions[id]?.name
    }

    func isActiveSession(_ sessionID: String) -> Bool {
        return sessionID == activeSessionID
    }

    func bufferOutput(_ sessionID: String, rawText: String) {
        if outputBuffers[sessionID] == nil {
            outputBuffers[sessionID] = []
        }
        outputBuffers[sessionID]!.append(rawText)
        if outputBuffers[sessionID]!.count > maxBufferEntries {
            outputBuffers[sessionID]!.removeFirst(outputBuffers[sessionID]!.count - maxBufferEntries)
        }
    }

    func drainBuffer(_ sessionID: String) -> [String] {
        return outputBuffers.removeValue(forKey: sessionID) ?? []
    }
}

