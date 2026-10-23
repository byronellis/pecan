import Foundation
import ArgumentParser
import Logging
import PecanProtocol
import PecanServer
import PecanSettings

extension Pecan.Server {
    struct Run : AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run the server in the foreground (clients start it this way automatically)")

        func run() async throws {
            LoggingSystem.bootstrap { label in
                var handler = StreamLogHandler.standardError(label: label)
                handler.logLevel = .info
                return handler
            }
            try await PecanServerHost.run()
        }
    }

    struct Start : AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start the server in the background, replacing an older build")

        func run() async throws {
            let connection = try await ServerConnector.connect()
            print("pecan server \(connection.server.build) running (pid \(connection.server.pid))")
            await connection.rpc.close()
        }
    }

    struct Stop : AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the server")

        func run() async throws {
            if try await ServerConnector.stop() {
                print("Stopped pecan server.")
            } else {
                print("No pecan server is running.")
            }
        }
    }

    struct Status : AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the running server")

        func run() async throws {
            let connection: ServerConnector.Connection
            do {
                connection = try await ServerConnector.connect(autoStart: false)
            } catch ServerConnector.ConnectError.notRunning {
                print("No pecan server is running (\(PecanPaths.socketPath)).")
                throw ExitCode(1)
            }
            let status = try await connection.rpc.call(GetStatus.self, Empty())
            await connection.rpc.close()

            let uptime = Duration.seconds(Date().timeIntervalSince(status.startedAt))
            print("pecan server \(status.build)")
            print("  pid      \(status.pid)")
            print("  uptime   \(uptime.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))")
            print("  clients  \(status.connectedClients)")
            print("  socket   \(PecanPaths.socketPath)")
            print("  log      \(PecanPaths.logPath)")
            if BuildInfo.current.supersedes(status.build) {
                print("This client is \(BuildInfo.current); the next `pecan` start will upgrade the server.")
            }
        }
    }
}
