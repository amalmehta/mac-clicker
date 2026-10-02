import Foundation

/// One MCP server to run, in the same shape Claude Desktop and friends use, so a
/// config can be moved between them without rewriting.
public struct MCPServerConfig: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let command: String
    public let args: [String]
    public let env: [String: String]
    public let enabled: Bool
    /// Drop every tool that could change something, before the model is told it
    /// exists. A guarantee rather than an instruction: the model cannot ask for
    /// what it was never offered.
    public let readOnly: Bool

    public init(
        name: String, command: String, args: [String] = [],
        env: [String: String] = [:], enabled: Bool = true, readOnly: Bool = false
    ) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
        self.readOnly = readOnly
    }
}

public enum MCPConfigError: LocalizedError, Equatable {
    case notAnObject
    case missingServersKey
    case serverNotAnObject(String)
    case missingCommand(String)

    public var errorDescription: String? {
        switch self {
        case .notAnObject:
            return "The config file should contain a JSON object."
        case .missingServersKey:
            return "No \"mcpServers\" key. See the example in Settings."
        case .serverNotAnObject(let name):
            return "\"\(name)\" should be an object with a \"command\"."
        case .missingCommand(let name):
            return "\"\(name)\" has no \"command\"."
        }
    }
}

public enum MCPConfigFile {

    /// Parses by hand rather than via Codable so a mistake in one server names that
    /// server, instead of failing the whole file with a key path.
    public static func parse(_ data: Data) throws -> [MCPServerConfig] {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any]
        else { throw MCPConfigError.notAnObject }

        guard let servers = object["mcpServers"] as? [String: Any] else {
            throw MCPConfigError.missingServersKey
        }

        return try servers.keys.sorted().map { name in
            guard let entry = servers[name] as? [String: Any] else {
                throw MCPConfigError.serverNotAnObject(name)
            }
            guard let command = entry["command"] as? String, !command.isEmpty else {
                throw MCPConfigError.missingCommand(name)
            }
            return MCPServerConfig(
                name: name,
                command: command,
                args: entry["args"] as? [String] ?? [],
                env: entry["env"] as? [String: String] ?? [:],
                // Absent means on, so an existing config from another app just works.
                enabled: entry["enabled"] as? Bool ?? true,
                readOnly: entry["readOnly"] as? Bool ?? false
            )
        }
    }

    public static let example = """
    {
      "mcpServers": {
        "notes": {
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/you/Notes"],
          "enabled": true,
          "readOnly": true
        }
      }
    }
    """
}

/// Tool names have to survive two constraints at once: the API accepts only
/// `[a-zA-Z0-9_-]{1,64}`, and two servers may each offer a `search`. Prefixing with
/// the server name solves both, as long as the result stays inside 64 characters.
public enum MCPToolName {
    public static let prefix = "mcp"

    public static func qualified(server: String, tool: String) -> String {
        let name = "\(prefix)_\(sanitize(server))_\(sanitize(tool))"
        guard name.count > 64 else { return name }
        // Trim the middle rather than the end: the tool name carries more meaning
        // than the server name, so the server part gives way first.
        let budget = 64 - prefix.count - 2 - sanitize(tool).count
        let server = String(sanitize(server).prefix(max(1, budget)))
        return String("\(prefix)_\(server)_\(sanitize(tool))".prefix(64))
    }

    /// Recovers which server a qualified name belongs to, given the servers in play.
    public static func resolve(
        _ qualified: String, among servers: [String]
    ) -> (server: String, tool: String)? {
        for server in servers {
            let head = "\(prefix)_\(sanitize(server))_"
            if qualified.hasPrefix(head) {
                return (server, String(qualified.dropFirst(head.count)))
            }
        }
        return nil
    }

    private static func sanitize(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let mapped = text.map { allowed.contains($0) ? $0 : "_" }
        return String(mapped)
    }
}
