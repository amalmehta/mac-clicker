import Foundation
import MacClickerKit

/// Speaks MCP to one server over its standard input and output.
///
/// Implements only what tools need — `initialize`, `tools/list`, `tools/call` — which
/// is the whole of the protocol that matters for this app. Messages are newline
/// delimited JSON-RPC 2.0.
@MainActor
final class MCPClient {

    struct Tool {
        let name: String
        let description: String
        /// The server's JSON Schema, passed through to the API untouched.
        let inputSchema: [String: Any]
    }

    enum Failure: LocalizedError {
        case launchFailed(String)
        case protocolError(String)
        case timedOut(String)
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let detail): return "Couldn't start the server: \(detail)"
            case .protocolError(let detail): return "Unexpected reply: \(detail)"
            case .timedOut(let what): return "\(what) timed out"
            case .serverError(let message): return message
            }
        }
    }

    let config: MCPServerConfig
    private(set) var tools: [Tool] = []

    private var process: Process?
    private var stdin: FileHandle?
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 1
    private var buffer = Data()
    private(set) var stderrTail = ""

    init(config: MCPServerConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    func start() async throws {
        let process = Process()
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()

        // `env` resolves the command against PATH, so configs can say "npx" rather
        // than an absolute path — and the PATH below is set explicitly because a
        // GUI app inherits a bare one, not the shell's, so Homebrew and nvm
        // installs would otherwise be invisible.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [config.command] + config.args
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extraPaths = [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
            "\(home)/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        let existing = environment["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        var seen = Set<String>()
        environment["PATH"] = (existing + extraPaths).filter { seen.insert($0).inserted }
            .joined(separator: ":")
        environment.merge(config.env) { _, configured in configured }
        process.environment = environment

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.recordStderr(text) }
        }

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed("\(config.command): \(error.localizedDescription)")
        }

        self.process = process
        self.stdin = inPipe.fileHandleForWriting

        _ = try await send("initialize", params: [
            // The oldest widely-supported revision: newer servers accept it, older
            // ones require it.
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "Mac Clicker", "version": "1.0"]
        ], timeout: 30)

        notify("notifications/initialized")
        tools = try await fetchTools()
    }

    func stop() {
        for (_, continuation) in pending {
            continuation.resume(throwing: Failure.serverError("Server stopped."))
        }
        pending = [:]
        stdin?.closeFile()
        process?.terminate()
        process = nil
        stdin = nil
    }

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Tools

    private func fetchTools() async throws -> [Tool] {
        let result = try await send("tools/list", params: [:], timeout: 30)
        guard let list = result["tools"] as? [[String: Any]] else {
            throw Failure.protocolError("tools/list returned no tools array")
        }
        return list.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return Tool(
                name: name,
                description: entry["description"] as? String ?? "",
                inputSchema: entry["inputSchema"] as? [String: Any]
                    ?? ["type": "object", "properties": [:]]
            )
        }
    }

    /// Calls a tool and flattens the reply to text, which is all the model needs.
    func call(_ tool: String, arguments: [String: Any], timeout: TimeInterval = 90) async throws -> String {
        let result = try await send(
            "tools/call", params: ["name": tool, "arguments": arguments], timeout: timeout
        )

        let blocks = result["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": return block["text"] as? String
            case "image": return "[image omitted]"
            case "resource":
                let resource = block["resource"] as? [String: Any]
                return resource?["text"] as? String ?? "[resource omitted]"
            default: return nil
            }
        }.joined(separator: "\n")

        // A tool that failed is not a transport failure: hand the message back so
        // the model can adapt instead of the whole run collapsing.
        if result["isError"] as? Bool == true {
            return "The tool reported an error: \(text.isEmpty ? "no detail given" : text)"
        }
        return text.isEmpty ? "(the tool returned nothing)" : text
    }

    // MARK: - JSON-RPC

    private func send(
        _ method: String, params: [String: Any]?, timeout: TimeInterval
    ) async throws -> [String: Any] {
        let id = nextID
        nextID += 1

        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        try write(message)

        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.pending[id] = continuation
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw Failure.timedOut("\(method) on \(self.config.name)")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw Failure.protocolError("no reply to \(method)")
            }
            pending[id] = nil
            return first
        }
    }

    private func notify(_ method: String) {
        try? write(["jsonrpc": "2.0", "method": method])
    }

    private func write(_ message: [String: Any]) throws {
        guard let stdin else { throw Failure.serverError("Server is not running.") }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        stdin.write(data)
    }

    // MARK: - Reading

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty,
              let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }

        // Notifications carry no id and nothing here subscribes to them.
        guard let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id)
        else { return }

        if let error = message["error"] as? [String: Any] {
            let detail = error["message"] as? String ?? "unknown error"
            continuation.resume(throwing: Failure.serverError(detail))
        } else {
            continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
        }
    }

    private func recordStderr(_ text: String) {
        stderrTail = String((stderrTail + text).suffix(2_000))
    }
}
