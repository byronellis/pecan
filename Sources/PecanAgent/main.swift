import Foundation
import GRPC
import NIO
import PecanShared
import PecanAgentCore
import Logging

let logger = Logger(label: "com.pecan.agent")

func main() async throws {
    let args = CommandLine.arguments

    // Invoke subcommand: pecan-agent invoke <tool_name> [<json_args>]
    if args.count >= 3 && args[1] == "invoke" {
        let toolName = args[2]
        let argsJSON = args.count >= 4 ? args[3] : "{}"
        await ToolManager.shared.registerBuiltinTools()
        await ToolManager.shared.loadTools()
        await SkillManager.shared.discoverSkills()
        await SkillManager.shared.registerLuaTools()
        do {
            let result = try await ToolManager.shared.executeTool(name: toolName, argumentsJSON: argsJSON)
            print(result)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        exit(0)
    }

    guard args.count > 1 else {
        logger.error("Usage: pecan-agent <session_id> [host_address]")
        exit(1)
    }

    let sessionID = args[1]
    let hostAddress = args.count > 2 ? args[2] : "127.0.0.1"
    let agentID = UUID().uuidString

    // Register built-in tools, then load user Lua tools, then hooks, then prompt fragments
    await ToolManager.shared.registerBuiltinTools()
    await ToolManager.shared.loadTools()
    await HookManager.shared.loadHooks()
    await SkillManager.shared.discoverSkills()
    await SkillManager.shared.registerLuaTools()
    await PromptComposer.shared.registerBuiltinFragments()
    await PromptComposer.shared.loadUserFragments()

#if os(Linux)
    // Create FUSE filesystem actors — mount all at startup before the gRPC event loop
    let memFS = MemoryFUSEFilesystem()
    let skillsFS = SkillsFUSEFilesystem(upperDir: "/tmp/skills-upper")

    // Mount COW overlay at /project if lower dir exists; upper dir is local to the container
    let lowerProjectDir = "/project-lower"
    let upperProjectDir = "/project-upper"
    if FileManager.default.fileExists(atPath: lowerProjectDir) {
        Thread.detachNewThread {
            do {
                let fd = try fuseOpenDevice()
                try fuseMountPoint("/project", fd: fd)
                let fs = COWOverlayFilesystem(lower: lowerProjectDir, upper: upperProjectDir)
                let server = FUSEServer(fd: fd, fs: fs)
                logger.info("Mounted COW overlay at /project (lower: \(lowerProjectDir), upper: \(upperProjectDir))")
                server.runOnThread()
            } catch {
                logger.error("Failed to mount project overlay: \(error)")
            }
        }
    }

    Thread.detachNewThread {
        do {
            let fd = try fuseOpenDevice()
            try fuseMountPoint("/memory", fd: fd)
            let server = FUSEServer(fd: fd, fs: memFS)
            logger.info("Mounted memory FUSE at /memory")
            server.runOnThread()
        } catch {
            logger.error("Failed to mount memory FUSE: \(error)")
        }
    }

    Thread.detachNewThread {
        do {
            let fd = try fuseOpenDevice()
            try fuseMountPoint("/skills", fd: fd)
            let server = FUSEServer(fd: fd, fs: skillsFS)
            logger.info("Mounted skills FUSE at /skills")
            server.runOnThread()
        } catch {
            logger.error("Failed to mount skills FUSE: \(error)")
        }
    }
#endif

    // Setup gRPC channel
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel: GRPCChannel
    if hostAddress.hasPrefix("/") {
        logger.info("Pecan Agent \(agentID) Starting for session: \(sessionID) connecting via Unix socket \(hostAddress)")
        channel = try GRPCChannelPool.with(
            target: .unixDomainSocket(hostAddress),
            transportSecurity: .plaintext,
            eventLoopGroup: group
        ) { config in
            config.keepalive = ClientConnectionKeepalive(
                interval: .seconds(15), timeout: .seconds(10),
                permitWithoutCalls: true, maximumPingsWithoutData: 0
            )
        }
    } else {
        logger.info("Pecan Agent \(agentID) Starting for session: \(sessionID) connecting to \(hostAddress):3000")
        channel = try GRPCChannelPool.with(
            target: .host(hostAddress, port: 3000),
            transportSecurity: .plaintext,
            eventLoopGroup: group
        ) { config in
            config.keepalive = ClientConnectionKeepalive(
                interval: .seconds(15), timeout: .seconds(10),
                permitWithoutCalls: true, maximumPingsWithoutData: 0
            )
            config.connectionBackoff = ConnectionBackoff(
                initialBackoff: 1.0, maximumBackoff: 60.0, multiplier: 1.6, jitter: 0.2
            )
        }
    }

    let client = Pecan_AgentServiceAsyncClient(channel: channel)
    let call = client.makeConnectCall()
    let writer = StreamWriter(call.requestStream)

    // Configure gRPC sub-clients with the send callback
    await TaskClient.shared.configure { msg in try await writer.send(msg) }
    await HttpClient.shared.configure { msg in try await writer.send(msg) }
    await MemoryClient.shared.configure { msg in try await writer.send(msg) }
    await SkillsClient.shared.configure { msg in try await writer.send(msg) }
    await ProjectToolClient.shared.configure { msg in try await writer.send(msg) }
    await SubagentPool.shared.configure(sink: writer)

    // Send registration
    var regMsg = Pecan_AgentEvent()
    var reg = Pecan_AgentRegistration()
    reg.agentID = agentID
    reg.sessionID = sessionID
    regMsg.register = reg
    try await writer.send(regMsg)

    // Build event handler — captures FUSE objects via callback on Linux
#if os(Linux)
    let handler = AgentEventHandler(
        sink: writer,
        agentID: agentID,
        sessionID: sessionID,
        onFUSERegistered: { [memFS, skillsFS] hasProject, hasTeam in
            await memFS.configure(hasProject: hasProject, hasTeam: hasTeam)
            Task.detached { await skillsFS.configure() }
            logger.info("Registration: FUSE configured")
        }
    )
#else
    let handler = AgentEventHandler(sink: writer, agentID: agentID, sessionID: sessionID)
#endif

    // Event loop — one handler call per message, sequential
    do {
        for try await command in call.responseStream {
            try await handler.handle(command)
        }
    } catch {
        logger.error("Disconnected from server: \(error)")
    }

    await writer.finish()
    logger.info("Pecan Agent Shutting Down.")
    try await channel.close().get()
    try await group.shutdownGracefully()
}

Task {
    do {
        try await main()
    } catch {
        logger.critical("Error: \(error)")
        exit(1)
    }
    exit(0)
}

RunLoop.main.run()
