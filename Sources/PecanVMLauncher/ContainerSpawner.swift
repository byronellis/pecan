import Foundation
import Containerization
import ContainerizationExtras
import ContainerizationOS
import Logging
import PecanShared

let logger = Logger(label: "com.pecan.vm-launcher")

/// A writer that outputs to a file.
public final class FileWriter: Writer, @unchecked Sendable {
    private let handle: FileHandle

    public init(handle: FileHandle) {
        self.handle = handle
    }

    public func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    public func close() throws {
        try handle.close()
    }
}

/// A spawner that creates an isolated Linux VM using Apple's Containerization framework.
@available(macOS 15.0, *)
actor ContainerSpawner {
    /// Maps sessionID → (containerName, container) so we can delete by the correct name.
    private var containers: [String: (name: String, container: LinuxContainer)] = [:]
    /// Shared manager reused across all containers (avoids stale state from manager recreation).
    private var sharedManager: ContainerManager?
    /// Counter to generate unique container names across restarts of the same session.
    private var restartCounters: [String: Int] = [:]

    init() {}

    /// Locate an uncompressed Linux kernel (vmlinux) for the VM.
    private func resolveKernelPath() throws -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        let userKernel = homeDir.appendingPathComponent(".pecan/vm/vmlinux").path
        if fm.fileExists(atPath: userKernel) {
            return userKernel
        }

        let containerKernel = homeDir.appendingPathComponent("Library/Application Support/com.apple.container/kernels/default.kernel-arm64").path
        if fm.fileExists(atPath: containerKernel) {
            return containerKernel
        }

        throw NSError(
            domain: "ContainerSpawner", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No uncompressed Linux kernel found. Provide ~/.pecan/vm/vmlinux or run: container system kernel set --recommended"]
        )
    }

    /// Lazily initialize and return the shared ContainerManager.
    private func getOrCreateManager() async throws -> ContainerManager {
        if let manager = sharedManager {
            return manager
        }
        let kernelPath = try resolveKernelPath()
        let initfsReference = "ghcr.io/apple/containerization/vminit:0.26.5"
        logger.info("Initializing shared ContainerManager with kernel: \(kernelPath), initfs: \(initfsReference)")
        let manager = try await ContainerManager(
            kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm),
            initfsReference: initfsReference,
            rosetta: false
        )
        sharedManager = manager
        return manager
    }

    func spawnAgent(sessionID: String, grpcSocketPath: String, agentName: String, mounts: [Pecan_LauncherMountSpec]) async throws {
        logger.info("Setting up Containerization VM for session \(sessionID) (agent: \(agentName))...")

        // If there's already a running container for this session, save it for background cleanup
        let oldEntry = containers[sessionID]
        if oldEntry != nil {
            logger.info("Session \(sessionID) already has a running container — will replace it")
        }

        var manager = try await getOrCreateManager()

        // Generate a unique container name to avoid collisions with recently deleted containers
        let counter = (restartCounters[sessionID] ?? 0) + 1
        restartCounters[sessionID] = counter
        let containerName = counter == 1 ? sessionID : "\(sessionID)-\(counter)"

        let imageReference = "docker.io/library/alpine:3.19"
        logger.info("Creating container \(containerName) from \(imageReference)...")

        let currentPath = FileManager.default.currentDirectoryPath
        let logDir = URL(fileURLWithPath: currentPath).appendingPathComponent(".run/containers")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("\(sessionID).log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let logWriter: FileWriter? = {
            guard let handle = try? FileHandle(forWritingTo: logFile) else { return nil }
            return FileWriter(handle: handle)
        }()
        if logWriter != nil {
            logger.info("Container output for \(sessionID) will be logged to \(logFile.path)")
        }
        let bootLog = BootLog.file(path: logFile)

        let hostSocketPath = URL(fileURLWithPath: grpcSocketPath)

        let container: LinuxContainer
        do {
            container = try await manager.create(
                containerName,
                reference: imageReference,
                rootfsSizeInBytes: 1024 * 1024 * 1024,
                networking: false
            ) { @Sendable config in
                config.cpus = 2
                config.memoryInBytes = 512 * 1024 * 1024

                config.bootLog = bootLog

                if let currentTerm = try? Terminal.current {
                    config.process.stdout = currentTerm
                    config.process.stderr = currentTerm
                } else if let logWriter = logWriter {
                    config.process.stdout = logWriter
                    config.process.stderr = logWriter
                } else {
                    logger.warning("Could not obtain Terminal.current or create log file for session \(sessionID).")
                }

                let guestSocketPath = URL(fileURLWithPath: "/tmp/grpc.sock")
                let socketConfig = UnixSocketConfiguration(
                    source: hostSocketPath,
                    destination: guestSocketPath,
                    direction: .into
                )
                config.sockets.append(socketConfig)
                logger.info("Configured Unix socket relay: \(hostSocketPath.path) -> \(guestSocketPath.path) (via vsock)")

                for mount in mounts {
                    let m = Mount.share(source: mount.source, destination: mount.destination)
                    config.mounts.append(m)
                    logger.debug("Mount: \(mount.source) -> \(mount.destination) (\(mount.readOnly ? "ro" : "rw"))")
                }

                config.process.arguments = ["/opt/pecan/pecan-agent", sessionID, "/tmp/grpc.sock"]
                config.process.workingDirectory = "/home/\(agentName)"
                config.process.environmentVariables.append("HOME=/home/\(agentName)")
                config.process.environmentVariables.append("USER=\(agentName)")

                logger.debug("Container config for \(sessionID): cpus=\(config.cpus), memory=\(config.memoryInBytes), args=\(config.process.arguments)")
            }
        } catch {
            logger.error("Failed to create container \(containerName): \(error)")
            throw error
        }

        logger.info("Starting lifecycle for container \(containerName)...")
        do {
            try await container.create()
            logger.debug("Container \(containerName) created successfully.")
            try await container.start()
            logger.info("Container \(containerName) started successfully.")
        } catch {
            logger.error("Failed to start container \(containerName): \(error)")
            try? await container.stop()
            try? manager.delete(containerName)
            throw error
        }

        containers[sessionID] = (name: containerName, container: container)

        // Tear down the old container in the background now that the new one is running
        if let old = oldEntry {
            var mgr = manager  // copy for the detached task
            Task.detached {
                logger.info("Cleaning up old container \(old.name) for session \(sessionID)...")
                try? await old.container.stop()
                _ = try? await old.container.wait()
                try? mgr.delete(old.name)
                logger.info("Old container \(old.name) cleaned up.")
            }
        }

        let capturedName = containerName
        Task.detached { [weak self] in
            do {
                let status = try await container.wait()
                logger.info("Container \(capturedName) for session \(sessionID) exited with status \(status)")
                // Only clean up if we haven't been terminated already (avoid double cleanup)
                if let entry = await self?.containers[sessionID], entry.name == capturedName {
                    try? await container.stop()
                    if var mgr = await self?.sharedManager {
                        try? mgr.delete(capturedName)
                    }
                    await self?.removeSession(sessionID)
                }
            } catch {
                logger.error("Error while waiting for container \(capturedName): \(error)")
            }
        }
    }

    func terminateAgent(sessionID: String) async throws {
        if let entry = containers[sessionID] {
            try await entry.container.stop()
            // Wait for the container process to fully exit so the socket relay is torn down
            _ = try? await entry.container.wait()
            if var manager = sharedManager {
                try? manager.delete(entry.name)
            }
            removeSession(sessionID)
            logger.info("Terminated container \(entry.name) for session \(sessionID)")
        }
    }

    private func removeSession(_ sessionID: String) {
        containers.removeValue(forKey: sessionID)
    }
}
