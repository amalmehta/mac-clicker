import Foundation
import MacClickerKit

/// Runs the MCP servers listed in the user's config and offers their tools to the
/// model.
///
/// The point of using MCP rather than writing connectors is that the integrations
/// already exist: a filesystem server over a notes folder, or any of the hosted ones,
/// costs a config entry instead of an OAuth implementation.
@MainActor
final class MCPRegistry: ObservableObject {

    enum State: Equatable {
        case disabled
        case starting
        case ready
        case failed(String)
    }

    struct ServerStatus: Identifiable {
        let id: String
        var state: State
        var toolNames: [String] = []
        /// Last output on the server's stderr, which is where the reason for a
        /// failure almost always is.
        var diagnostics: String = ""
    }

    @Published private(set) var statuses: [ServerStatus] = []
    @Published private(set) var configProblem: String?

    private var clients: [String: MCPClient] = [:]

    static var configURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return support.appendingPathComponent("MacClicker/mcp.json")
    }

    var hasConfig: Bool { FileManager.default.fileExists(atPath: Self.configURL.path) }

    var readyToolCount: Int {
        statuses.filter { $0.state == .ready }.reduce(0) { $0 + $1.toolNames.count }
    }

    /// Writes the example config so there is something to edit rather than a blank file.
    func createExampleConfig() throws {
        let url = Self.configURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try Data(MCPConfigFile.example.utf8).write(to: url)
    }

    // MARK: - Lifecycle

    func reload() async {
        shutdown()
        configProblem = nil
        statuses = []

        guard hasConfig else { return }

        let configs: [MCPServerConfig]
        do {
            configs = try MCPConfigFile.parse(try Data(contentsOf: Self.configURL))
        } catch {
            configProblem = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return
        }

        statuses = configs.map { config in
            ServerStatus(id: config.name, state: config.enabled ? .starting : .disabled)
        }

        // Started concurrently: one server fetching a package over the network
        // should not hold up the others.
        await withTaskGroup(of: Void.self) { group in
            for config in configs where config.enabled {
                group.addTask { @MainActor in await self.start(config) }
            }
        }
    }

    private func start(_ config: MCPServerConfig) async {
        let client = MCPClient(config: config)
        do {
            try await client.start()
            clients[config.name] = client
            update(config.name) {
                $0.state = .ready
                $0.toolNames = client.tools.map(\.name).sorted()
            }
        } catch {
            client.stop()
            update(config.name) {
                $0.state = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
                $0.diagnostics = client.stderrTail
            }
        }
    }

    func shutdown() {
        clients.values.forEach { $0.stop() }
        clients = [:]
    }

    private func update(_ name: String, _ change: (inout ServerStatus) -> Void) {
        guard let index = statuses.firstIndex(where: { $0.id == name }) else { return }
        change(&statuses[index])
    }

    // MARK: - Tools

    /// Builds the tool set handed to the model.
    ///
    /// `consent` is asked before anything that would change the world. Tools that
    /// only read run freely — being asked to approve a note lookup three times in one
    /// answer is how people learn to approve without reading.
    func tools(
        consent: @escaping (_ summary: String, _ detail: String) async -> Bool
    ) -> [String: AnthropicClient.Tool] {

        var built: [String: AnthropicClient.Tool] = [:]

        for (serverName, client) in clients {
            for tool in client.tools {
                let qualified = MCPToolName.qualified(server: serverName, tool: tool.name)
                let risk = ActionClassifier.risk(label: "\(tool.name) \(tool.description)")

                var schema = tool.inputSchema
                if schema["type"] == nil { schema["type"] = "object" }

                let description = tool.description.isEmpty
                    ? "\(tool.name), from the \(serverName) server."
                    : "\(tool.description) (from the \(serverName) server)"

                built[qualified] = AnthropicClient.Tool(
                    definition: [
                        "name": qualified,
                        "description": description,
                        "input_schema": schema
                    ],
                    handler: { [weak client] arguments in
                        guard let client else { return "That server is no longer running." }

                        if risk == .consequential {
                            let allowed = await consent(
                                "Run \(tool.name) in \(serverName)?",
                                Self.describe(arguments)
                            )
                            guard allowed else {
                                return "The user declined to run this. Do not try it again; carry on without it or explain what you would have done."
                            }
                        }

                        do {
                            return try await client.call(tool.name, arguments: arguments)
                        } catch {
                            return "The tool failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                        }
                    }
                )
            }
        }
        return built
    }

    /// Renders the arguments for the confirmation card, so approval is given against
    /// what will actually happen rather than against a tool's name.
    private static func describe(_ arguments: [String: Any]) -> String {
        guard !arguments.isEmpty else { return "No arguments." }
        return arguments.keys.sorted().map { key in
            let value = String(describing: arguments[key] ?? "")
            let shown = value.count > 160 ? String(value.prefix(160)) + "…" : value
            return "\(key): \(shown)"
        }.joined(separator: "\n")
    }
}
