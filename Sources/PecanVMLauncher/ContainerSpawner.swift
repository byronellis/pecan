import Foundation
import Containerization
import ContainerizationExtras
import ContainerizationOS
import Logging

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
    private var containers: [String: LinuxContainer] = [:]
    private var managers: [String: ContainerManager] = [:]

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

    func spawnAgent(sessionID: String, grpcSocketPath: String, agentName: String, mounts: [MountSpec]) async throws {
        logger.info("Setting up Containerization VM for session \(sessionID) (agent: \(agentName))...")

        let kernelPath = try resolveKernelPath()
        let initfsReference = "ghcr.io/apple/containerization/vminit:0.26.5"

        logger.info("Initializing ContainerManager with kernel: \(kernelPath), initfs: \(initfsReference)")

        var manager: ContainerManager
        do {
            manager = try await ContainerManager(
                kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm),
                initfsReference: initfsReference,
                rosetta: false
            )
        } catch {
            logger.error("Failed to initialize ContainerManager: \(error)")
            throw error
        }

        let imageReference = "docker.io/library/alpine:3.19"
        logger.info("Creating container \(sessionID) from \(imageReference)...")

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
                sessionID,
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
            logger.error("Failed to create container \(sessionID): \(error)")
            throw error
        }

        logger.info("Starting lifecycle for container \(sessionID)...")
        do {
            try await container.create()
            logger.debug("Container \(sessionID) created successfully.")
            try await container.start()
            logger.info("Container \(sessionID) started successfully.")
        } catch {
            logger.error("Failed to start container \(sessionID): \(error)")
            try? await container.stop()
            try? manager.delete(sessionID)
            throw error
        }

        containers[sessionID] = container
        managers[sessionID] = manager

        Task.detached { [weak self] in
            do {
                let status = try await container.wait()
                logger.info("Container for session \(sessionID) exited with status \(status)")
                try? await container.stop()
                var mgr = manager
                try? mgr.delete(sessionID)
                await self?.removeSession(sessionID)
            } catch {
                logger.error("Error while waiting for container \(sessionID): \(error)")
            }
        }
    }

    func terminateAgent(sessionID: String) async throws {
        if let container = containers[sessionID] {
            try await container.stop()
            if var manager = managers[sessionID] {
                try? manager.delete(sessionID)
            }
            removeSession(sessionID)
            logger.info("Terminated container for session \(sessionID)")
        }
    }

    private func removeSession(_ sessionID: String) {
        containers.removeValue(forKey: sessionID)
        managers.removeValue(forKey: sessionID)
    }
}
