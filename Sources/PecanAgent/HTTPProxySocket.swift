#if os(Linux)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Wire types

private struct ProxyRequest: Codable {
    let method: String
    let url: String
    let headers: [[String: String]]   // [{name, value}]
    let body: String?
}

private struct ProxyResponse: Codable {
    let status: Int
    let body: String
    let error: String
}

// MARK: - Socket server (runs on a dedicated OS thread)

let httpProxySocketPath = "/tmp/pecan-http.sock"

/// Start the HTTP proxy Unix socket server on a dedicated thread.
/// Each incoming connection is handled synchronously (one at a time per connection)
/// while bridging to the async HttpClient via DispatchSemaphore.
func startHTTPProxySocket() {
    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sock >= 0 else {
        logger.error("HTTPProxySocket: failed to create socket")
        return
    }

    unlink(httpProxySocketPath)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 108) { path in
            _ = strlcpy(path, httpProxySocketPath, 108)
        }
    }
    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else {
        logger.error("HTTPProxySocket: bind failed: \(String(cString: strerror(errno)))")
        close(sock)
        return
    }
    guard listen(sock, 16) == 0 else {
        logger.error("HTTPProxySocket: listen failed")
        close(sock)
        return
    }
    logger.info("HTTPProxySocket: listening at \(httpProxySocketPath)")

    while true {
        let client = accept(sock, nil, nil)
        guard client >= 0 else { continue }
        let sema = DispatchSemaphore(value: 0)
        Task {
            defer { close(client); sema.signal() }
            await handleProxyClient(fd: client)
        }
        sema.wait()
    }
}

private func handleProxyClient(fd: Int32) async {
    // Read one newline-terminated JSON line (up to 1MB)
    var lineBuf = [UInt8](repeating: 0, count: 1024 * 1024)
    var lineLen = 0
    while lineLen < lineBuf.count {
        let n = read(fd, &lineBuf[lineLen], 1)
        if n <= 0 { return }
        if lineBuf[lineLen] == UInt8(ascii: "\n") { break }
        lineLen += 1
    }

    func sendError(_ msg: String) {
        let resp = ProxyResponse(status: 0, body: "", error: msg)
        if let data = try? JSONEncoder().encode(resp),
           var str = String(data: data, encoding: .utf8) {
            str += "\n"
            _ = str.withCString { write(fd, $0, strlen($0)) }
        }
    }

    guard lineLen > 0,
          let req = try? JSONDecoder().decode(ProxyRequest.self, from: Data(bytes: lineBuf, count: lineLen)) else {
        sendError("Invalid request JSON")
        return
    }

    let headers = req.headers.compactMap { d -> (name: String, value: String)? in
        guard let n = d["name"], let v = d["value"] else { return nil }
        return (name: n, value: v)
    }

    do {
        let resp = try await HttpClient.shared.sendRequest(
            method: req.method,
            url: req.url,
            headers: headers,
            body: req.body ?? "",
            requiresApproval: false
        )
        let out = ProxyResponse(status: Int(resp.statusCode), body: resp.body, error: "")
        if let data = try? JSONEncoder().encode(out),
           var str = String(data: data, encoding: .utf8) {
            str += "\n"
            _ = str.withCString { write(fd, $0, strlen($0)) }
        }
    } catch {
        sendError(error.localizedDescription)
    }
}

// MARK: - fetch subcommand (client side — called as `pecan-agent fetch [curl/wget args]`)

func runFetchSubcommand() {
    var method = "GET"
    var url = ""
    var headers: [[String: String]] = []
    var body: String? = nil
    var outputFile: String? = nil
    var outputFromURL = false
    var failOnError = false
    var wgetMode = false
    var includeHeaders = false

    var argv = Array(CommandLine.arguments.dropFirst(2))

    // Mode flag
    if argv.first == "--wget" {
        wgetMode = true
        argv.removeFirst()
    }

    func addHeader(name: String, value: String) {
        headers.append(["name": name, "value": value])
    }

    func parseHeaderString(_ hdr: String) {
        guard let colon = hdr.firstIndex(of: ":") else { return }
        let name = String(hdr[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(hdr[hdr.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        addHeader(name: name, value: value)
    }

    var i = 0
    while i < argv.count {
        let arg = argv[i]

        if wgetMode {
            switch arg {
            case "-O", "--output-document":
                i += 1; if i < argv.count { outputFile = argv[i] }
            case "-q", "--quiet", "--no-verbose": break
            case "--post-data":
                i += 1; if i < argv.count { body = argv[i]; method = "POST" }
            case "--method":
                i += 1; if i < argv.count { method = argv[i] }
            case "--body-data":
                i += 1; if i < argv.count { body = argv[i] }
            case "--header":
                i += 1; if i < argv.count { parseHeaderString(argv[i]) }
            case "-P": i += 1  // ignore directory prefix
            default:
                if arg.hasPrefix("--output-document=") {
                    outputFile = String(arg.dropFirst("--output-document=".count))
                } else if arg.hasPrefix("--post-data=") {
                    body = String(arg.dropFirst("--post-data=".count)); method = "POST"
                } else if arg.hasPrefix("--method=") {
                    method = String(arg.dropFirst("--method=".count))
                } else if arg.hasPrefix("--header=") {
                    parseHeaderString(String(arg.dropFirst("--header=".count)))
                } else if !arg.hasPrefix("-") {
                    url = arg
                }
            }
        } else {
            // curl mode
            switch arg {
            case "-X", "--request":
                i += 1; if i < argv.count { method = argv[i] }
            case "-H", "--header":
                i += 1; if i < argv.count { parseHeaderString(argv[i]) }
            case "-d", "--data", "--data-raw", "--data-ascii", "--data-binary":
                i += 1
                if i < argv.count {
                    body = argv[i]
                    if method == "GET" { method = "POST" }
                }
            case "-o", "--output":
                i += 1; if i < argv.count { outputFile = argv[i] }
            case "-O": outputFromURL = true
            case "-u", "--user":
                i += 1
                if i < argv.count {
                    let encoded = Data(argv[i].utf8).base64EncodedString()
                    addHeader(name: "Authorization", value: "Basic \(encoded)")
                }
            case "-A", "--user-agent":
                i += 1; if i < argv.count { addHeader(name: "User-Agent", value: argv[i]) }
            case "-e", "--referer":
                i += 1; if i < argv.count { addHeader(name: "Referer", value: argv[i]) }
            case "-f", "--fail": failOnError = true
            case "-I", "--head": method = "HEAD"
            case "-i", "--include": includeHeaders = true
            // Flags that take a value we skip
            case "-b", "--cookie", "-c", "--cookie-jar", "-r", "--range",
                 "-t", "--telnet-option", "-T", "--upload-file",
                 "-w", "--write-out", "--connect-timeout", "--max-time",
                 "-m", "--retry", "--retry-delay", "--retry-max-time":
                i += 1
            // Flags we silently ignore (no value)
            case "-s", "--silent", "-S", "--show-error", "-L", "--location",
                 "-k", "--insecure", "-v", "--verbose", "-g", "--globoff",
                 "-G", "--get", "-n", "--netrc", "-N", "--no-buffer",
                 "--compressed", "-#", "--progress-bar", "-q", "--disable":
                break
            default:
                if arg.hasPrefix("--") && arg.contains("=") { break }  // unknown --key=val
                if !arg.hasPrefix("-") { url = arg }
            }
        }
        i += 1
    }

    guard !url.isEmpty else {
        fputs(wgetMode ? "wget: missing URL\n" : "curl: no URL specified\n", stderr)
        exit(1)
    }

    if outputFromURL {
        let path = url.components(separatedBy: "?").first ?? url
        outputFile = (path as NSString).lastPathComponent
        if outputFile?.isEmpty == true { outputFile = "index.html" }
    }

    // Build request JSON
    struct FetchRequest: Codable {
        let method: String; let url: String
        let headers: [[String: String]]; let body: String?
    }
    struct FetchResponse: Codable {
        let status: Int; let body: String; let error: String
    }

    guard let reqData = try? JSONEncoder().encode(FetchRequest(method: method, url: url, headers: headers, body: body)) else {
        fputs("curl: internal error encoding request\n", stderr); exit(1)
    }

    // Connect to the proxy socket
    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sock >= 0 else {
        fputs("curl: (7) failed to create socket\n", stderr); exit(7)
    }
    defer { close(sock) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 108) { path in
            _ = strlcpy(path, httpProxySocketPath, 108)
        }
    }
    let connectResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        fputs("curl: (7) couldn't connect to pecan HTTP proxy — is the agent running?\n", stderr)
        exit(7)
    }

    // Send request
    var reqStr = String(data: reqData, encoding: .utf8)! + "\n"
    _ = reqStr.withCString { write(sock, $0, strlen($0)) }

    // Read response (newline-terminated JSON, up to 16MB)
    var respBuf = [UInt8](repeating: 0, count: 16 * 1024 * 1024)
    var respLen = 0
    while respLen < respBuf.count {
        let n = read(sock, &respBuf[respLen], 1)
        if n <= 0 { break }
        if respBuf[respLen] == UInt8(ascii: "\n") { break }
        respLen += 1
    }

    guard let resp = try? JSONDecoder().decode(FetchResponse.self, from: Data(bytes: respBuf, count: respLen)) else {
        fputs("curl: failed to parse proxy response\n", stderr); exit(1)
    }

    if !resp.error.isEmpty {
        fputs("\(wgetMode ? "wget" : "curl"): \(resp.error)\n", stderr); exit(1)
    }
    if failOnError && resp.status >= 400 {
        fputs("curl: (22) The requested URL returned error: \(resp.status)\n", stderr); exit(22)
    }

    let bodyBytes = resp.body.data(using: .utf8) ?? Data()

    if let outFile = outputFile {
        do { try bodyBytes.write(to: URL(fileURLWithPath: outFile)) }
        catch { fputs("curl: failed to write \(outFile): \(error)\n", stderr); exit(1) }
    } else {
        if includeHeaders { print("HTTP/1.1 \(resp.status)") }
        FileHandle.standardOutput.write(bodyBytes)
    }
}

// MARK: - Script installation

/// Write curl and wget shim scripts to /usr/local/bin/ so agents can use them from bash.
func installHTTPShims() {
    let shimContent = "#!/bin/sh\nexec /opt/pecan/pecan-agent fetch \"$@\"\n"
    let wgetContent = "#!/bin/sh\nexec /opt/pecan/pecan-agent fetch --wget \"$@\"\n"
    let fm = FileManager.default
    for (path, content) in [("/usr/local/bin/curl", shimContent), ("/usr/local/bin/wget", wgetContent)] {
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        } catch {
            logger.warning("HTTPShims: could not install \(path): \(error)")
        }
    }
    logger.info("HTTPShims: installed curl and wget shims in /usr/local/bin/")
}
#endif
