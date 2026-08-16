import Foundation

/// A live connection to one MCP server.
///
/// The server is a child process: requests go down its stdin, replies come back up its
/// stdout, one JSON object per line. Nothing here is concurrent — one request is written,
/// one reply is read — which is enough for a CLI asking a handful of questions and keeps
/// the whole thing legible.
///
/// stderr is left attached to ours rather than swallowed. MCP servers report their real
/// problems there — a missing token, a failed OAuth refresh — and a client that hides it
/// turns every misconfiguration into a silent hang.
public final class MCPClient {
    private let process = Process()
    private let toServer = Pipe()
    private let fromServer = Pipe()
    private var nextID = 1
    private var pending = Data()

    public let name: String

    public init(name: String, config: MCP.ServerConfig) {
        self.name = name
        // Through a login shell, so a server installed by npm, brew, uv or mise is found
        // the same way it would be if the person ran it themselves. Resolving the command
        // ourselves would work until the first time somebody used a version manager.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let command = ([config.command] + config.args)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        process.arguments = ["-lc", command]
        process.environment = ProcessInfo.processInfo.environment.merging(config.env) { _, new in new }
        process.standardInput = toServer
        process.standardOutput = fromServer
    }

    deinit { if process.isRunning { process.terminate() } }

    /// Start the server and shake hands.
    ///
    /// The handshake is two messages, and the second one is easy to forget: after the
    /// server answers `initialize`, the client must send an `initialized` notification.
    /// Servers that follow the spec strictly will refuse everything until it arrives, and
    /// the symptom is a client that hangs on its first real request with no error at all.
    @discardableResult
    public func start(timeout: TimeInterval = 30) throws -> String {
        do { try process.run() } catch {
            throw MCP.Failure.notRunning(error.localizedDescription)
        }

        let result = try send("initialize", params: [
            "protocolVersion": MCP.protocolVersion,
            "capabilities": [:],
            "clientInfo": ["name": "dunes", "version": "1"],
        ], timeout: timeout)

        try write(MCP.notification(method: "notifications/initialized"))

        let info = result["serverInfo"] as? [String: Any]
        return info?["name"] as? String ?? name
    }

    public func tools(timeout: TimeInterval = 30) throws -> [MCP.Tool] {
        MCP.tools(in: try send("tools/list", params: [:], timeout: timeout))
    }

    public func call(_ tool: String, arguments: [String: Any] = [:],
                     timeout: TimeInterval = 120) throws -> MCP.ToolResult {
        let result = try send("tools/call",
                              params: ["name": tool, "arguments": arguments],
                              timeout: timeout)
        let outcome = MCP.toolResult(in: result)
        if outcome.isError { throw MCP.Failure.toolFailed(outcome.text) }
        return outcome
    }

    public func stop() {
        toServer.fileHandleForWriting.closeFile()
        if process.isRunning { process.terminate() }
    }

    // MARK: - The wire

    private func send(_ method: String, params: [String: Any]?,
                      timeout: TimeInterval) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try write(MCP.request(id: id, method: method, params: params))
        return try MCP.result(of: try readReply(to: id, timeout: timeout))
    }

    private func write(_ data: Data) throws {
        guard process.isRunning else {
            throw MCP.Failure.notRunning("it exited before the request was sent")
        }
        try toServer.fileHandleForWriting.write(contentsOf: data)
    }

    /// Read lines until one is the reply we asked for.
    ///
    /// Anything else is skipped rather than rejected: servers emit notifications, and a
    /// good number of them print a startup banner to stdout despite stdout being the
    /// protocol channel. Failing on the first non-JSON line would make this client
    /// useless against half of what people actually run.
    private func readReply(to id: Int, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        let handle = fromServer.fileHandleForReading

        while Date() < deadline {
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard !line.isEmpty else { continue }
                if MCP.isReply(Data(line), to: id) { return Data(line) }
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                throw MCP.Failure.notRunning("it closed its output before replying")
            }
            pending.append(chunk)
        }
        throw MCP.Failure.badReply("no reply within \(Int(timeout))s")
    }
}
