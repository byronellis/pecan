import Foundation
import Containerization
import ContainerizationOS

@main
struct PecanBuilder {
    static func main() async throws {
        print("PecanBuilder: Compiling pecan-agent for Linux using Apple Containerization")
        
        let fm = FileManager.default
        let currentDirectory = URL(fileURLWithPath: fm.currentDirectoryPath)
        let homeDir = fm.homeDirectoryForCurrentUser
        let vmDir = homeDir.appendingPathComponent(".pecan/vm")
        let kernelPath = vmDir.appendingPathComponent("vmlinuz").path
        
        guard fm.fileExists(atPath: kernelPath) else {
            print("Error: Kernel not found at \(kernelPath). Please download it.")
            exit(1)
        }
        
        // Set up terminal in raw mode (optional but good for seeing output properly)
        let current = try? Terminal.current
        
        let initfsReference = "ghcr.io/apple/containerization/vminit:0.13.0"
        
        var manager = try await ContainerManager(
            kernel: Kernel(path: URL(fileURLWithPath: kernelPath), platform: .linuxArm),
            initfsReference: initfsReference,
            rosetta: true
        )
        
        // Use official Swift image to build
        let imageReference = "docker.io/library/swift:6.0"
        let containerId = "pecan-builder-run"
        
        print("Creating container from \(imageReference)...")
        
        // Clean up from previous aborted runs just in case
        try? manager.delete(containerId)
        
        let container = try await manager.create(
            containerId,
            reference: imageReference,
            rootfsSizeInBytes: 4 * 1024 * 1024 * 1024 // 4GB for toolchain + build
        ) { @Sendable config in
            config.cpus = 4
            config.memoryInBytes = 4 * 1024 * 1024 * 1024 // 4 GB RAM
            
            // Output to terminal
            config.process.stdout = current
            config.process.stderr = current
            
            // Mount the workspace
            let workspaceMount = Mount.share(source: currentDirectory.path, destination: "/workspace")
            config.mounts.append(workspaceMount)
            
            // Run swift build
            config.process.arguments = ["/bin/bash", "-c", "cd /workspace && swift build -c release --product pecan-agent"]
            config.process.workingDirectory = "/workspace"
        }
        
        print("Starting builder container...")
        try await container.create()
        try await container.start()
        
        if let current = current {
            try? await container.resize(to: try current.size)
        }
        
        let status = try await container.wait()
        try await container.stop()
        
        try? manager.delete(containerId)
        
        let exitCode = status.exitCode
        print("\nBuilder container exited with code \(exitCode)")
        if exitCode == 0 {
            print("Successfully built Linux agent at .build/aarch64-unknown-linux-gnu/release/pecan-agent")
        } else {
            exit(exitCode)
        }
    }
}
