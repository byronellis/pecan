import Foundation
#if os(macOS)
import Virtualization
#endif
import PecanShared
import Logging

public protocol AgentSpawner {
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
/// A spawner that creates an isolated Linux VM using Apple's Virtualization.framework.
/// Note: This requires a Linux kernel, initrd, and a rootfs, along with a cross-compiled Linux pecan-agent binary.
public actor VZLinuxSpawner: AgentSpawner {
    private var vms: [String: VZVirtualMachine] = [:]
    
    public init() {}
    
    public func spawnAgent(sessionID: String) async throws {
        logger.info("Setting up Virtualization.framework Linux VM for session \(sessionID)...")
        
        let config = VZVirtualMachineConfiguration()
        config.platform = VZGenericPlatformConfiguration()
        
        // Define paths (In a real scenario, these would be downloaded or bundled)
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let vmDir = homeDir.appendingPathComponent(".pecan/vm")
        let kernelURL = vmDir.appendingPathComponent("vmlinuz")
        let initrdURL = vmDir.appendingPathComponent("initrd.img")
        let diskURL = vmDir.appendingPathComponent("rootfs.ext4")
        
        // For development/stubbing, we check if the files exist. If not, we throw an informative error.
        guard FileManager.default.fileExists(atPath: kernelURL.path),
              FileManager.default.fileExists(atPath: diskURL.path) else {
            logger.error("Missing VM assets at \(vmDir.path). Falling back to LocalProcessSpawner or failing.")
            throw NSError(domain: "VZLinuxSpawner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Linux kernel or rootfs missing. Please provision ~/.pecan/vm/ with vmlinuz and rootfs.ext4"])
        }
        
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        if FileManager.default.fileExists(atPath: initrdURL.path) {
            bootLoader.initialRamdiskURL = initrdURL
        }
        
        // Command line tells the kernel to mount the rootfs and run our agent initialization
        // We can pass the sessionID into the kernel command line so the agent knows who it is.
        bootLoader.commandLine = "console=hvc0 root=/dev/vda rw init=/bin/pecan-agent-init session_id=\(sessionID)"
        config.bootLoader = bootLoader
        
        config.cpuCount = 2
        config.memorySize = 1024 * 1024 * 1024 // 1GB
        
        // Setup rootfs block device
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]
        
        // Virtio Console (serial port) for logging
        let consoleConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
        let stdioAttachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: .standardOutput)
        consoleConfig.attachment = stdioAttachment
        config.serialPorts = [consoleConfig]
        
        // Networking (NAT to access the host's gRPC server at 10.0.2.2 usually, or specific host IP)
        let networkConfig = VZVirtioNetworkDeviceConfiguration()
        networkConfig.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkConfig]
        
        // Shared directory for Virtual Filesystem (VFS)
        // We can share a specific workspace directory with the VM
        let workspaceDir = vmDir.appendingPathComponent("workspace_\(sessionID)")
        try? FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let share = VZSharedDirectory(url: workspaceDir, readOnly: false)
        let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "pecan_vfs")
        fsConfig.share = VZSingleDirectoryShare(directory: share)
        config.directorySharingDevices = [fsConfig]
        
        try config.validate()
        
        let vm = VZVirtualMachine(configuration: config)
        
        // Start the VM
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.start { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
        
        vms[sessionID] = vm
        logger.info("Linux VM started successfully for session \(sessionID)")
    }
    
    public func terminateAgent(sessionID: String) async throws {
        if let vm = vms[sessionID] {
            if vm.canRequestStop {
                try vm.requestStop()
            } else {
                vm.stop { _ in }
            }
            vms.removeValue(forKey: sessionID)
            logger.info("Terminated Linux VM for session \(sessionID)")
        }
    }
}
#endif

/// A factory to determine which spawner to use.
public actor SpawnerFactory {
    public static let shared = SpawnerFactory()
    
    // For now, we default to local process until the user provisions the Linux kernel assets.
    // We can make this configurable via Config.swift in the future.
    public var activeSpawner: AgentSpawner = LocalProcessSpawner()
    
    public func useVirtualizationFramework() {
        #if os(macOS)
        activeSpawner = VZLinuxSpawner()
        #else
        logger.warning("Virtualization.framework is only available on macOS. Falling back to LocalProcessSpawner.")
        #endif
    }
    
    public func spawn(sessionID: String) async throws {
        try await activeSpawner.spawnAgent(sessionID: sessionID)
    }
    
    public func terminate(sessionID: String) async throws {
        try await activeSpawner.terminateAgent(sessionID: sessionID)
    }
}
