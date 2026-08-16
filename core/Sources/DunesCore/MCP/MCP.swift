import Foundation

/// Talking to an MCP server.
///
/// Model Context Protocol servers are ordinary programs that speak JSON-RPC 2.0 over
/// their own stdin and stdout, one message per line. That is the whole transport, which
/// is why this is a few hundred lines rather than a dependency: a client needs to spawn a
/// process, shake hands, ask what tools exist, and call one.
///
/// Everything in this file is pure — building requests, reading replies, reading the
/// config. The process itself lives in `MCPClient`, so the parts with edge cases can be
/// checked without spawning anything.
public enum MCP {

    /// The protocol version this client speaks. Sent in the handshake; a server that
    /// wants a different one says so and we use whatever it answers with, because being
    /// strict here would break against every server that moves first.
    public static let protocolVersion = "2025-06-18"

    // MARK: - Configuration

    /// One server, as written in `mcp.json`.
    ///
    /// The shape is deliberately the same one Claude Desktop and every other MCP client
    /// uses — a `mcpServers` object of name → {command, args, env} — so a server someone
    /// has already configured somewhere else can be pasted in whole.
    public struct ServerConfig: Sendable, Equatable, Codable {
        public var command: String
        public var args: [String]
        public var env: [String: String]

        public init(command: String, args: [String] = [], env: [String: String] = [:]) {
            self.command = command
            self.args = args
            self.env = env
        }

        private enum CodingKeys: String, CodingKey { case command, args, env }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decode(String.self, forKey: .command)
            args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
            env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        }
    }

    /// Where the servers are written down, and what they are.
    ///
    /// A file rather than a table in the database: it holds commands and environment
    /// variables, it is the kind of thing a person edits by hand, and the database is
    /// meant to be copyable without carrying somebody's tokens along with it.
    public struct Configuration: Sendable, Equatable {
        public var servers: [String: ServerConfig]

        public init(servers: [String: ServerConfig] = [:]) { self.servers = servers }

        public static func url(in workspace: URL) -> URL {
            workspace.appendingPathComponent("mcp.json")
        }

        /// Missing is not an error — it means no servers, which is the normal state.
        public static func load(from workspace: URL) throws -> Configuration {
            let url = Self.url(in: workspace)
            guard let data = try? Data(contentsOf: url) else { return Configuration() }
            return try decode(data)
        }

        public static func decode(_ data: Data) throws -> Configuration {
            struct File: Decodable { var mcpServers: [String: ServerConfig]? }
            let file = try JSONDecoder().decode(File.self, from: data)
            return Configuration(servers: file.mcpServers ?? [:])
        }
    }

    // MARK: - What a server offers

    public struct Tool: Sendable, Equatable {
        public let name: String
        public let description: String
        /// The tool's JSON Schema, kept as written. Nothing here interprets it; it is
        /// shown to a person deciding what to call and passed along untouched.
        public let schema: String

        public init(name: String, description: String, schema: String) {
            self.name = name
            self.description = description
            self.schema = schema
        }
    }

    /// One piece of what a tool handed back.
    public struct Content: Sendable, Equatable {
        public let kind: String
        public let text: String

        public init(kind: String, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public struct ToolResult: Sendable, Equatable {
        public let content: [Content]
        /// Servers report tool failures in the result rather than as JSON-RPC errors,
        /// so a call can succeed at the protocol level and still have gone wrong.
        public let isError: Bool

        public init(content: [Content], isError: Bool) {
            self.content = content
            self.isError = isError
        }

        public var text: String {
            content.filter { $0.kind == "text" }.map(\.text).joined(separator: "\n\n")
        }
    }

    // MARK: - Framing

    public enum Failure: Error, CustomStringConvertible {
        case notRunning(String)
        case badReply(String)
        case server(code: Int, message: String)
        case toolFailed(String)
        case noSuchServer(String)

        public var description: String {
            switch self {
            case .notRunning(let why):    "the server didn't start: \(why)"
            case .badReply(let what):     "the server said something unexpected: \(what)"
            case .server(let code, let message): "the server returned error \(code): \(message)"
            case .toolFailed(let message): "the tool failed: \(message)"
            case .noSuchServer(let name): "no server called \"\(name)\" in mcp.json"
            }
        }
    }

    /// One JSON-RPC request, as a single line with its newline already on it.
    public static func request(id: Int, method: String, params: [String: Any]? = nil) throws -> Data {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        return try line(message)
    }

    /// A notification: same shape, no id, no reply ever comes.
    public static func notification(method: String, params: [String: Any]? = nil) throws -> Data {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        return try line(message)
    }

    private static func line(_ message: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    /// The `result` of a reply, or the error it carried instead.
    ///
    /// Servers write to stdout for the protocol and, in practice, sometimes for logging
    /// as well — so a line that isn't JSON, or is JSON without an `id`, is skipped by the
    /// reader rather than treated as a protocol violation. This function only sees lines
    /// that got that far.
    public static func result(of data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badReply(String(data: data, encoding: .utf8) ?? "not text")
        }
        if let error = object["error"] as? [String: Any] {
            throw Failure.server(code: error["code"] as? Int ?? 0,
                                 message: error["message"] as? String ?? "no message")
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    /// True when this line is a reply to the request we're waiting on. Notifications and
    /// server-initiated requests carry a different id, or none.
    public static func isReply(_ data: Data, to id: Int) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["id"] as? Int == id
    }

    // MARK: - Reading the two replies that matter

    public static func tools(in result: [String: Any]) -> [Tool] {
        let listed = result["tools"] as? [[String: Any]] ?? []
        return listed.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let schema = entry["inputSchema"].flatMap {
                try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .prettyPrinted])
            }
            return Tool(
                name: name,
                description: entry["description"] as? String ?? "",
                schema: schema.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            )
        }
    }

    public static func toolResult(in result: [String: Any]) -> ToolResult {
        let items = result["content"] as? [[String: Any]] ?? []
        let content = items.map { item in
            Content(
                kind: item["type"] as? String ?? "text",
                // Non-text content — an image, a resource link — is kept as a note of
                // what it was rather than dropped, so a caller can see that something
                // came back that this client can't read yet.
                text: item["text"] as? String
                    ?? (item["uri"] as? String).map { "[\(item["type"] as? String ?? "resource"): \($0)]" }
                    ?? ""
            )
        }
        return ToolResult(content: content, isError: result["isError"] as? Bool ?? false)
    }
}
