import Foundation
import Logging
import PecanSettings

private let serverLogger = Logger(label: "com.pecan.mlx-manager")

public actor MLXServerManager {
    public static let shared = MLXServerManager()
    private var activeProcesses: [String: Process] = [:]

    private init() {}

    public func ensureRunning(provider: ProviderConfig) async {
        guard provider.type.lowercased() == "mlx",
              let repo = provider.huggingfaceRepo, !repo.isEmpty,
              let urlStr = provider.url,
              let url = URL(string: urlStr),
              let host = url.host else { return }

        let port = url.port ?? 8080

        // Check if already running
        if await isServerAlive(url: url) {
            serverLogger.info("MLX server already running at \(urlStr)")
            return
        }

        // If a process is already tracked, terminate it to restart fresh
        if let oldProc = activeProcesses[provider.id] {
            oldProc.terminate()
            activeProcesses.removeValue(forKey: provider.id)
        }

        serverLogger.info("Launching local MLX server for \(repo) on port \(port)...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-m", "mlx_lm.server", "--model", repo, "--port", "\(port)", "--host", host]
        
        let logsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pecan/logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logPath = logsDir.appendingPathComponent("mlx-\(provider.id).log").path
        FileManager.default.createFile(atPath: logPath, contents: nil)

        if let logHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        do {
            try process.run()
            activeProcesses[provider.id] = process
            serverLogger.info("MLX server process started (PID \(process.processIdentifier)). Logs: \(logPath)")

            // Wait for it to become alive (up to 45 seconds for model load)
            for _ in 0..<90 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if await isServerAlive(url: url) {
                    serverLogger.info("MLX server is now online at \(urlStr)")
                    return
                }
                if !process.isRunning {
                    serverLogger.error("MLX server process exited prematurely. Check logs at: \(logPath)")
                    break
                }
            }
        } catch {
            serverLogger.error("Failed to launch MLX server: \(error.localizedDescription)")
        }
    }

    private func isServerAlive(url: URL) async -> Bool {
        let checkURL = url.appendingPathComponent("v1/models")
        var req = URLRequest(url: checkURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 1.0
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) {
                return true
            }
        } catch {}
        return false
    }

    public func shutdownAll() {
        for (id, proc) in activeProcesses {
            if proc.isRunning {
                serverLogger.info("Terminating MLX server process for \(id)...")
                proc.terminate()
            }
        }
    }
}
