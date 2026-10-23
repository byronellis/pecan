import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ANSITerminal
import PecanSettings
import PecanAgentCore
import PecanServer
import ArgumentParser
import TUISuite


func defaultConfigLocation() -> String {
    if let env = ProcessInfo.processInfo.environment["PECAN_CONFIG"], !env.isEmpty {
        return env
    } else {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".pecan/config.yaml").path
    }
}

@main
struct Pecan : ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pecan - a Swift-based Agent",
        subcommands: [Config.self,Agent.self,Server.self],
        defaultSubcommand: Agent.self)

    
    @Option(help:"Path to configuration file")
    var configPath: String = defaultConfigLocation()
    
    private func configExists() -> Bool {
        FileManager.default.fileExists(atPath: configPath)
    }
    
    

    struct Config : ParsableCommand {
        mutating func run() {
            Configurator.run()
        }

    }
    struct Agent : ParsableCommand {
        mutating func run() {
            
        }
    }
    struct Server : ParsableCommand {
        mutating func run() {
            
        }

    }

    
    
}
