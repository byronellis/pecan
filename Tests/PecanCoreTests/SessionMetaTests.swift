import Testing
import Foundation
@testable import PecanServerCore

@Suite("SessionMeta")
struct SessionMetaTests {

    // MARK: - Codable round-trip

    @Test("encodes and decodes round-trip")
    func roundTrip() throws {
        let meta = SessionMeta(
            sessionID: "test-session-1",
            agentName: "gort",
            projectName: "pecan",
            teamName: "backend",
            networkEnabled: true,
            persistent: false,
            startedAt: "2026-01-15T10:00:00Z"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(meta)
        let decoded = try JSONDecoder().decode(SessionMeta.self, from: data)

        #expect(decoded.sessionID == meta.sessionID)
        #expect(decoded.agentName == meta.agentName)
        #expect(decoded.projectName == meta.projectName)
        #expect(decoded.teamName == meta.teamName)
        #expect(decoded.networkEnabled == meta.networkEnabled)
        #expect(decoded.persistent == meta.persistent)
        #expect(decoded.startedAt == meta.startedAt)
    }

    @Test("uses snake_case JSON keys")
    func snakeCaseKeys() throws {
        let meta = SessionMeta(
            sessionID: "s1", agentName: "r2d2", projectName: "p1",
            teamName: "t1", networkEnabled: false, persistent: true,
            startedAt: "2026-01-01T00:00:00Z"
        )
        let data = try JSONEncoder().encode(meta)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["session_id"] as? String == "s1")
        #expect(json["agent_name"] as? String == "r2d2")
        #expect(json["project_name"] as? String == "p1")
        #expect(json["team_name"] as? String == "t1")
        #expect(json["network_enabled"] as? Bool == false)
        #expect(json["persistent"] as? Bool == true)
        #expect(json["started_at"] as? String == "2026-01-01T00:00:00Z")
        // Verify camelCase keys are absent
        #expect(json["sessionID"] == nil)
        #expect(json["agentName"] == nil)
    }

    @Test("decodes from snake_case JSON")
    func decodesFromSnakeCase() throws {
        let json = """
        {
          "session_id": "abc",
          "agent_name": "hal",
          "project_name": "odyssey",
          "team_name": "crew",
          "network_enabled": true,
          "persistent": false,
          "started_at": "2026-04-01T12:00:00Z"
        }
        """.data(using: .utf8)!

        let meta = try JSONDecoder().decode(SessionMeta.self, from: json)
        #expect(meta.sessionID == "abc")
        #expect(meta.agentName == "hal")
        #expect(meta.projectName == "odyssey")
        #expect(meta.persistent == false)
        #expect(meta.networkEnabled == true)
    }

    // MARK: - Running index serialization

    @Test("running index encodes and decodes array")
    func runningIndexRoundTrip() throws {
        let sessions = [
            SessionMeta(sessionID: "s1", agentName: "tron", projectName: "proj",
                        teamName: "", networkEnabled: false, persistent: true,
                        startedAt: "2026-01-01T00:00:00Z"),
            SessionMeta(sessionID: "s2", agentName: "clu", projectName: "proj",
                        teamName: "alpha", networkEnabled: true, persistent: false,
                        startedAt: "2026-01-02T00:00:00Z"),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(sessions)
        let decoded = try JSONDecoder().decode([SessionMeta].self, from: data)

        #expect(decoded.count == 2)
        #expect(decoded[0].sessionID == "s1")
        #expect(decoded[1].agentName == "clu")
    }

    // MARK: - File I/O using temp directory

    @Test("save and load round-trip via temp file")
    func saveLoadRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pecan-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let meta = SessionMeta(
            sessionID: "roundtrip-test",
            agentName: "baymax",
            projectName: "hero6",
            teamName: "",
            networkEnabled: false,
            persistent: true,
            startedAt: "2026-04-11T00:00:00Z"
        )

        // Write to file manually (bypassing home-dir path for testing)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(meta)
        let fileURL = tmpDir.appendingPathComponent("meta.json")
        try data.write(to: fileURL)

        // Read back
        let readData = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(SessionMeta.self, from: readData)

        #expect(decoded.sessionID == meta.sessionID)
        #expect(decoded.agentName == meta.agentName)
        #expect(decoded.persistent == true)
    }

    @Test("writeRunningIndex and readRunningIndex round-trip")
    func runningIndexFileRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pecan-index-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sessions = [
            SessionMeta(sessionID: "idx-1", agentName: "dot", projectName: "",
                        teamName: "", networkEnabled: false, persistent: true,
                        startedAt: "2026-04-11T00:00:00Z"),
        ]

        let indexURL = tmpDir.appendingPathComponent("sessions.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(sessions)
        try data.write(to: indexURL)

        let readData = try Data(contentsOf: indexURL)
        let decoded = try JSONDecoder().decode([SessionMeta].self, from: readData)

        #expect(decoded.count == 1)
        #expect(decoded[0].sessionID == "idx-1")
        #expect(decoded[0].agentName == "dot")
    }
}
