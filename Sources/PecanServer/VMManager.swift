import Foundation
#if os(macOS)
import Containerization
import ContainerizationOS
#endif
import PecanShared
import Logging

public protocol AgentSpawner: Sendable {
    func spawnAgent(sessionID: String) async throws
    func terminateAgent(sessionID: String) async throws
}

/// A spawner that just runs the agent as a local subprocess. Useful for development.
public actor LocalProcessSpawner: AgentSpawner {
    private var processes: [String: Process] = [:]
    
    public init() {}
    
    public func spawnAgent(sessionID: String) async throws {
        logger.info("Spawning local agent process for session \(sessionID)...")
        let task = Process()
        let currentPath = FileManager.default.currentDirectoryPath
        task.executableURL = URL(fileURLWithPath: "\(currentPath)/.build/debug/pecan-agent")
        task.arguments = [sessionID]
        
        // Inherit standard output so we can see it in the server logs
        task.standardOutput = FileHandle.standardOutput
        task.standardError = FileHandle.standardError
        
        try task.run()
        processes[sessionID] = task
    }
    
    public func terminateAgent(sessionID: String) async throws {
        if let task = processes[sessionID] {
            task.terminate()
            processes.removeValue(forKey: sessionID)
            logger.info("Terminated local agent for session \(sessionID)")
        }
    }
}

#if os(macOS)
/// A spawner that creates an isolated Linux VM using Apple's Containerization framework.
@available(macOS 15.0, *)
public actor AppleContainerSpawner: AgentSpawner {
    private var containers: [String: LinuxContainer] = [:]
    
    public init() {}
    
    public func spawnAgent(sessionID: String) async throws {
        logger.info("Setting up Containerization VM for session \(sessionID)...")
        
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let vmDir = homeDir.appendingPathComponent(".pecan/vm")
        let kernelPath = vmDir.appendingPathComponent("vmlinuz").path
        
        guard FileManager.default.fileExists(atPath: kernelPath) else {
            logger.error("Missing VM kernel at \(kernelPath). Falling back to LocalProcessSpawner.")
            throw NSError(domain: "AppleContainerSpawner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Linux kernel missing. Please run ./build_linux_vm.sh or provision ~/.pecan/vm/vmlinuz"])
        }
        
        let initfsReference = "ghcr.io/apple/containerization/vminit:0.13.0"
        
        var manager = try await ContainerManager(
            kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm),
            initfsReference: initfsReference
        )
        
        // Let's use a minimal Alpine image as the base
        let imageReference = "docker.io/library/alpine:3.19"
        logger.info("Creating container from \(imageReference)...")
        
        let container = try await manager.create(
            sessionID,
            reference: imageReference,
            rootfsSizeInBytes: 1024 * 1024 * 1024 // 1GB
        ) { @Sendable config in
            config.cpus = 2
            config.memoryInBytes = 512 * 1024 * 1024 // 512 MB
            
            // Pipe the container's output back to our server's standard out
            if let currentTerm = try? Terminal.current {
                config.process.stdout = currentTerm
                config.process.stderr = currentTerm
            }
            
            // Mount the directory containing our statically compiled agent and tools
            let currentPath = FileManager.default.currentDirectoryPath
            let agentMount = Mount.share(source: "\(currentPath)/.build/aarch64-swift-linux-musl/release", destination: "/opt/pecan")
            
            // Also mount the tools directory
            let toolsMount = Mount.share(source: "\(homeDir.path)/.pecan/tools", destination: "/root/.pecan/tools")
            
            config.mounts.append(agentMount)
            config.mounts.append(toolsMount)
            
            // Host IP inside an Apple NAT network is usually 192.168.64.1 or handled automatically by DHCP
            // We'll pass an empty string for the host so the agent falls back to detecting its gateway
            config.process.arguments = ["/opt/pecan/pecan-agent", sessionID, "192.168.64.1"]
            config.process.workingDirectory = "/opt/pecan"
        }
        
        try await container.create()
        try await container.start()
        
        containers[sessionID] = container
        logger.info("Apple Container started successfully for session \(sessionID)")
        
        // We can optionally wait for the container to exit in a background task
        Task.detached {
            let code = try? await container.wait()
            try? await container.stop()
            try? manager.delete(sessionID)
            print("Container for session \(sessionID) exited with code \(String(describing: code))")
        }
    }
    
    public func terminateAgent(sessionID: String) async throws {
        if let container = containers[sessionID] {
            try await container.stop()
            containers.removeValue(forKey: sessionID)
            logger.info("Terminated Apple Container for session \(sessionID)")
        }
    }
}
#endif

/// A factory to determine which spawner to use.
public actor SpawnerFactory {
    public static let shared = SpawnerFactory()
    
    public var activeSpawner: AgentSpawner = LocalProcessSpawner()
    
    public func useVirtualizationFramework() {
        #if os(macOS)
        activeSpawner = AppleContainerSpawner()
        #else
        logger.warning("Virtualization framework via apple/containerization is only available on macOS. Falling back to LocalProcessSpawner.")
        #endif
    }
    
    public func spawn(sessionID: String) async throws {
        try await activeSpawner.spawnAgent(sessionID: sessionID)
    }
    
    public func terminate(sessionID: String) async throws {
        try await activeSpawner.terminateAgent(sessionID: sessionID)
    }
}