import Foundation
import Containerization
import ContainerizationExtras
import ContainerizationOS
import ContainerizationEXT4
import ContainerizationArchive
import Logging
import PecanShared
import SystemPackage

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

/// A Writer that logs each write call before delegating to an inner writer.
final class LoggingWriter: Writer, @unchecked Sendable {
    private let inner: any Writer
    private let sessionID: String

    init(inner: any Writer, sessionID: String) {
        self.inner = inner
        self.sessionID = sessionID
    }

    func write(_ data: Data) throws {
        logger.info("execShell[\(sessionID)]: stdout write \(data.count) bytes")
        try inner.write(data)
    }

    func close() throws {
        logger.info("execShell[\(sessionID)]: stdout closed")
        try inner.close()
    }
}

/// A ReaderStream backed by a raw file descriptor (e.g. a socket).
final class SocketReaderStream: ReaderStream, @unchecked Sendable {
    private let fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    func stream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            Task.detached {
                let bufSize = 4096
                let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)
                defer { buf.deallocate() }
                while true {
                    let n = read(self.fd, buf, bufSize)
                    if n <= 0 { break }
                    continuation.yield(Data(bytes: buf, count: n))
                }
                continuation.finish()
            }
        }
    }
}

/// Unpack an env tar into an EXT4 formatter, stripping `trusted.overlay.*` xattrs.
///
/// Overlayfs sets `trusted.overlay.origin` on the upper root directory to record
/// the lower layer's identity. If a snapshot exports this xattr and we restore it
/// verbatim, vminitd rejects the mount with ESTALE because the xattr references
/// the original container's lower-layer UUID, not the new one. Stripping it at
/// restore time lets overlayfs treat the layer as a fresh upper dir.
///
/// This mirrors the logic in `EXT4.Formatter.unpack(reader:)` (Formatter+Unpack.swift)
/// but filters xattrs before passing each entry to the formatter.
@available(macOS 15.0, *)
private func unpackStrippingOverlayXattrs(formatter: EXT4.Formatter, source: URL) throws {
    let reader = try ArchiveReader(file: source)
    let bufferSize = 128 * 1024
    let reusableBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bufferSize)
    defer { reusableBuffer.deallocate() }

    var hardlinks: [FilePath: FilePath] = [:]

    for (entry, streamReader) in reader.makeStreamingIterator() {
        guard var pathStr = entry.path else { continue }

        // Normalise path (matches preProcessPath in Formatter+Unpack)
        if pathStr.hasPrefix("./") { pathStr = String(pathStr.dropFirst()) }
        if !pathStr.hasPrefix("/") { pathStr = "/" + pathStr }
        let path = FilePath(pathStr)

        // Strip trusted.overlay.* xattrs — these encode lower-layer identity and
        // must not survive a round-trip or overlayfs will reject the mount.
        var xattrs = entry.xattrs
        xattrs = xattrs.filter { !$0.key.hasPrefix("trusted.overlay.") }
        entry.xattrs = xattrs

        // Handle whiteouts (OCI layer convention)
        if path.lastComponent?.string.hasPrefix(".wh.") == true {
            continue  // skip whiteouts — they only matter for full-rootfs restore
        }

        // Defer hardlinks to a second pass (same as Formatter+Unpack)
        if let hardlink = entry.hardlink {
            var hl = hardlink
            if hl.hasPrefix("./") { hl = String(hl.dropFirst()) }
            if !hl.hasPrefix("/") { hl = "/" + hl }
            hardlinks[path] = FilePath(hl)
            continue
        }

        let ts = FileTimestamps(
            access: entry.contentAccessDate,
            modification: entry.modificationDate,
            creation: entry.creationDate
        )

        switch entry.fileType {
        case .directory:
            try formatter.create(
                path: path,
                mode: EXT4.Inode.Mode(.S_IFDIR, entry.permissions),
                ts: ts, uid: entry.owner, gid: entry.group, xattrs: xattrs
            )
        case .regular:
            try formatter.create(
                path: path,
                mode: EXT4.Inode.Mode(.S_IFREG, entry.permissions),
                ts: ts, buf: streamReader, uid: entry.owner, gid: entry.group,
                xattrs: xattrs, fileBuffer: reusableBuffer
            )
        case .symbolicLink:
            let target = entry.symlinkTarget.map { FilePath($0) }
            try formatter.create(
                path: path, link: target,
                mode: EXT4.Inode.Mode(.S_IFLNK, entry.permissions),
                ts: ts, uid: entry.owner, gid: entry.group, xattrs: xattrs
            )
        default:
            continue
        }
    }

    // Second pass: create hardlinks
    for (link, target) in hardlinks {
        try? formatter.link(link: link, target: target)
    }
}

/// A spawner that creates an isolated Linux VM using Apple's Containerization framework.
@available(macOS 15.0, *)
actor ContainerSpawner {
    /// Maps sessionID → container entry so we can delete by the correct name.
    private var containers: [String: (name: String, container: LinuxContainer)] = [:]
    /// Shared manager reused across all containers (avoids stale state from manager recreation).
    private var sharedManager: ContainerManager?
    /// Counter to generate unique container names across restarts of the same session.
    private var restartCounters: [String: Int] = [:]

    // Writable overlay layer capacity. The upper layer only holds the diff
    // from the base image (installed packages etc.), so 2 GB is generous.
    private static let writableLayerSize: UInt64 = 2 * 1024 * 1024 * 1024

    init() {}

    /// Root directory of the Containerization framework's storage for a given container.
    private func containerStorageDir(containerName: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("com.apple.containerization")
            .appendingPathComponent("containers")
            .appendingPathComponent(containerName)
    }

    /// Path to the writable overlay layer (upper layer diff) for a given container.
    private func writableLayerPath(containerName: String) -> URL {
        containerStorageDir(containerName: containerName).appendingPathComponent("writable.ext4")
    }

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
        let network: ContainerManager.Network?
        if #available(macOS 26, *) {
            network = try ContainerManager.VmnetNetwork()
        } else {
            network = nil
        }
        let manager = try await ContainerManager(
            kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm),
            initfsReference: initfsReference,
            network: network,
            rosetta: false
        )
        sharedManager = manager
        return manager
    }

    func spawnAgent(sessionID: String, grpcSocketPath: String, agentName: String, mounts: [Pecan_LauncherMountSpec], networkEnabled: Bool = false, envMountPath: String = "") async throws {
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

        // Delete any stale container with the same name left over from a previous server run.
        // manager.delete is a no-op if the name doesn't exist, but it may throw if the
        // container is in an unexpected state — ignore errors here, create will fail loudly.
        try? manager.delete(containerName)

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
                rootfsSizeInBytes: 512 * 1024 * 1024,
                writableLayerSizeInBytes: Self.writableLayerSize,
                networking: networkEnabled
            ) { @Sendable config in
                config.cpus = 2
                config.memoryInBytes = 512 * 1024 * 1024

                config.bootLog = bootLog

                if let logWriter = logWriter {
                    config.process.stdout = logWriter
                    config.process.stderr = logWriter
                } else {
                    logger.warning("Could not create log file for session \(sessionID) — agent output will be lost.")
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
                    let opts: [String] = mount.readOnly ? ["ro"] : []
                    let m = Mount.share(source: mount.source, destination: mount.destination, options: opts)
                    config.mounts.append(m)
                    logger.debug("Mount: \(mount.source) -> \(mount.destination) (\(mount.readOnly ? "ro" : "rw"))")
                }

                // Patch /etc/passwd so getpwuid(0) returns the agent's home dir,
                // create directories, then exec the agent.
                let home = "/home/\(agentName)"
                // vminitd fully configures the network (ip link up, ip addr add, default route,
                // /etc/resolv.conf) before our process starts — no manual setup needed here.
                let networkSetup = ""
                let initCmd = """
                    \(networkSetup)rm -f /usr/local/bin/curl /usr/local/bin/wget && \
                    sed -i 's|^root:.*|root:x:0:0:root:\(home):/bin/ash|' /etc/passwd && \
                    mkdir -p \(home) && \
                    cd \(home) && \
                    exec /opt/pecan/pecan-agent '\(sessionID)' /tmp/grpc.sock
                    """
                config.process.arguments = ["/bin/sh", "-c", initCmd]
                config.process.workingDirectory = "/" // shell cds into home before exec
                config.process.environmentVariables.append("HOME=\(home)")
                config.process.environmentVariables.append("USER=\(agentName)")

                logger.debug("Container config for \(sessionID): cpus=\(config.cpus), memory=\(config.memoryInBytes), args=\(config.process.arguments)")
            }
        } catch {
            logger.error("Failed to create container \(containerName): \(error)")
            throw error
        }

        // Restore saved environment by populating the fresh writable.ext4 with the saved diff.
        // manager.create() just created a fresh empty writable.ext4; we overwrite it using
        // EXT4.Formatter so vminitd mounts a clean upper layer containing the saved packages.
        // This avoids the xino ESTALE issue from restoring a live-captured block device image.
        //
        // We write to a temp file first so that a failure never corrupts writable.ext4
        // (EXT4.Formatter.init truncates the target file before writing).
        let writablePath = writableLayerPath(containerName: containerName)
        let envURL = URL(fileURLWithPath: envMountPath)
        if !envMountPath.isEmpty {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: envMountPath, isDirectory: &isDir)
            if exists && !isDir.boolValue {
                let tempPath = writablePath.deletingPathExtension().appendingPathExtension("tmp.ext4")
                do {
                    logger.info("Restoring environment from \(envMountPath)...")
                    let formatter = try EXT4.Formatter(
                        FilePath(tempPath.path),
                        minDiskSize: Self.writableLayerSize
                    )
                    // Custom unpack that strips trusted.overlay.* xattrs so that
                    // vminitd can mount a fresh overlayfs without xino origin verification
                    // failing against the wrong lower-layer UUID.
                    try unpackStrippingOverlayXattrs(
                        formatter: formatter,
                        source: envURL
                    )
                    try formatter.close()
                    try FileManager.default.replaceItem(
                        at: writablePath,
                        withItemAt: tempPath,
                        backupItemName: nil,
                        options: [],
                        resultingItemURL: nil
                    )
                    logger.info("Environment restored successfully into writable layer.")
                } catch {
                    try? FileManager.default.removeItem(at: tempPath)
                    logger.warning("Failed to restore environment (will start fresh): \(error)")
                }
            }
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
        var capturedManager = manager
        Task.detached { [weak self] in
            do {
                let status = try await container.wait()
                logger.info("Container \(capturedName) for session \(sessionID) exited with status \(status)")
                // Only clean up if we haven't been terminated already (avoid double cleanup)
                if let entry = await self?.containers[sessionID], entry.name == capturedName {
                    try? await container.stop()
                    try? capturedManager.delete(capturedName)
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

    /// Snapshot the running container's environment to `outputPath` on the host.
    ///
    /// Strategy: flush dirty kernel buffers inside the container with sync(1), then
    /// read the writable.ext4 (overlay upper layer) directly on the host using
    /// EXT4.EXT4Reader and export it to a tar archive.  The resulting tar contains
    /// only the diff from the base Alpine image — installed packages, config changes,
    /// etc. — and is small regardless of base image size.
    ///
    /// On restore (next spawnAgent call with envMountPath set), EXT4.Formatter
    /// unpacks this tar into a fresh writable.ext4 before the container starts, so
    /// vminitd mounts a clean upper layer with the saved state pre-populated.
    func saveEnvironment(sessionID: String, outputPath: String) async throws {
        guard let entry = containers[sessionID] else {
            throw NSError(domain: "ContainerSpawner", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "No running container for session \(sessionID)"])
        }

        // Flush dirty kernel buffers so the writable.ext4 on the host is up-to-date.
        let syncProc = try await entry.container.exec(UUID().uuidString) { config in
            config.arguments = ["/bin/sh", "-c", "sync"]
            config.workingDirectory = "/"
        }
        try await syncProc.start()
        _ = try? await syncProc.wait()
        logger.info("sync completed for session \(sessionID)")

        let writablePath = writableLayerPath(containerName: entry.name)
        guard FileManager.default.fileExists(atPath: writablePath.path) else {
            throw NSError(domain: "ContainerSpawner", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Writable layer not found at \(writablePath.path)"])
        }

        let destURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destURL)

        logger.info("Exporting writable layer \(writablePath.path) -> \(outputPath)...")
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(writablePath.path))
        try reader.export(archive: FilePath(outputPath))

        logger.info("Environment snapshot saved to \(outputPath)")
    }

    func execShell(sessionID: String, command: [String], socketFD: Int32) async {
        guard let entry = containers[sessionID] else {
            let msg = "error: no running container for session \(sessionID)\n"
            _ = msg.withCString { write(socketFD, $0, Int(strlen($0))) }
            close(socketFD)
            return
        }

        let container = entry.container
        let handle = FileHandle(fileDescriptor: socketFD, closeOnDealloc: false)
        let writer = LoggingWriter(inner: FileWriter(handle: handle), sessionID: sessionID)
        let reader = SocketReaderStream(fd: socketFD)
        let interactive = command.isEmpty
        let cmd = interactive ? ["/bin/sh"] : command

        do {
            logger.info("execShell: calling container.exec for session \(sessionID)")
            let process = try await container.exec(UUID().uuidString) { config in
                config.arguments = cmd
                config.environmentVariables = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "TERM=xterm-256color"]
                config.workingDirectory = "/"
                config.stdin = reader
                config.stdout = writer
                config.stderr = writer
                config.terminal = interactive
            }
            logger.info("execShell: container.exec returned, calling process.start")
            try await process.start()
            logger.info("execShell: process started, waiting for exit")
            _ = try? await process.wait()
            logger.info("execShell: process exited")
        } catch {
            let msg = "exec error: \(error)\n"
            _ = msg.withCString { write(socketFD, $0, Int(strlen($0))) }
            logger.error("execShell error: \(error)")
        }
        close(socketFD)
    }
}
