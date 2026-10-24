import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import PecanSettings
import PecanAgentCore
import PecanServer
import PecanProtocol
import ArgumentParser
import Synchronization


func defaultConfigLocation() -> String {
    if let env = ProcessInfo.processInfo.environment["PECAN_CONFIG"], !env.isEmpty {
        return env
    } else {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".pecan/config.yaml").path
    }
}

@main
struct Pecan : AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pecan - a Swift-based Agent",
        subcommands: [Agent.self, Server.self],
        defaultSubcommand: Agent.self)

    
    @Option(help:"Path to configuration file")
    var configPath: String = defaultConfigLocation()
    
    private func configExists() -> Bool {
        FileManager.default.fileExists(atPath: configPath)
    }
    
    

    struct Agent : AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Chat with a model (the default command)")

        @Option(name: .shortAndLong, help: "Instructions for the model")
        var instructions: String?

        @Argument(help: "A message to answer non-interactively. Read from standard input when it isn't a terminal.")
        var message: [String] = []

        mutating func run() async throws {
            // Connecting starts the server, or upgrades it, as needed.
            let connection = try await ServerConnector.connect()
            defer { Task { await connection.rpc.close() } }
            let session = try await connection.rpc.call(
                OpenSession.self, .init(instructions: instructions))

            if !message.isEmpty || !Terminal.isInteractive {
                let text = message.isEmpty
                    ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    : message.joined(separator: " ")
                try await respondOnce(to: text, in: session, over: connection.rpc)
            } else {
                await ChatApp(rpc: connection.rpc, session: session).run()
            }
            await connection.rpc.close()
        }

        /// Streams one reply to standard output as plain text, for scripts and pipes.
        private func respondOnce(to text: String, in session: SessionInfo, over rpc: RPCConnection) async throws {
            // Bytes of the reply written so far, or nil once the reply is in and the rest is
            // written from it; the printer may still hold streamed text the reply overtook.
            let written = Mutex<Int?>(0)
            let printer = Task {
                for await notification in rpc.notifications where notification.method == SessionEvent.name {
                    guard case .text(let delta) = try? notification.decode(SessionEvent.self).event else { continue }
                    written.withLock { count in
                        guard let current = count else { return }
                        FileHandle.standardOutput.write(Data(delta.utf8))
                        count = current + delta.utf8.count
                    }
                }
            }
            defer { printer.cancel() }
            let result = try await rpc.call(SendMessage.self, .init(sessionID: session.id, text: text), timeout: nil)
            written.withLock { count in
                FileHandle.standardOutput.write(Data(result.text.utf8.dropFirst(count ?? 0)))
                count = nil
            }
            print()
        }
    }

    struct Server : AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage the resident pecan server",
            subcommands: [Run.self, Start.self, Stop.self, Status.self],
            defaultSubcommand: Run.self)
    }

    
    
}
