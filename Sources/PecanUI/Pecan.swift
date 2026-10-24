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
        mutating func run() async throws {
            // Connecting starts the server, or upgrades it, as needed. The TUI client builds on this.
            let connection = try await ServerConnector.connect()
            print("Connected to pecan server \(connection.server.build) (pid \(connection.server.pid))")
            await connection.rpc.close()
        }
    }
    struct Server : AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage the resident pecan server",
            subcommands: [Run.self, Start.self, Stop.self, Status.self],
            defaultSubcommand: Run.self)
    }

    
    
}
