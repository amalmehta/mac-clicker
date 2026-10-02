import Foundation

enum AnthropicError: LocalizedError {
    case missingAPIKey
    case http(status: Int, message: String)
    case refusal(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key yet. Open Settings from the menu bar icon and paste an Anthropic API key."
        case .http(let status, let message):
            switch status {
            case 401: return "The API key was rejected (401). Check it in Settings."
            case 429: return "Rate limited (429). Wait a moment and try again."
            case 500...599: return "Anthropic returned a \(status). Try again in a moment."
            default: return "Request failed (\(status)): \(message)"
            }
        case .refusal(let explanation):
            return explanation.isEmpty ? "Claude declined to answer for this selection." : explanation
        case .transport(let message):
            return message
        }
    }
}

struct StreamResult {
    /// The model that actually produced the answer — may differ from the requested
    /// one if a server-side fallback ran.
    var model: String = AnthropicClient.model
    var outputTokens: Int?
    var rounds: Int = 1
}

/// Content blocks for a user turn.
enum UserContent {
    static func text(_ value: String) -> [String: Any] {
        ["type": "text", "text": value]
    }

    static func pngImage(_ data: Data) -> [String: Any] {
        [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": "image/png",
                "data": data.base64EncodedString()
            ]
        ]
    }
}

@MainActor
enum AnthropicClient {
    nonisolated static let model = "claude-opus-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// A tool the model may call. `handler` runs locally and returns the result text.
    struct Tool {
        let definition: [String: Any]
        let handler: ([String: Any]) -> String
    }

    /// Streams a response, running any tools the model calls and continuing until it
    /// stops asking for them. One round for a plain answer; several when the model is
    /// walking through steps and pointing at each one.
    @discardableResult
    static func run(
        system: String,
        content: [[String: Any]],
        tools: [String: Tool] = [:],
        effort: Effort,
        maxRounds: Int = 6,
        onDelta: (String) -> Void
    ) async throws -> StreamResult {
        guard let apiKey = Keychain.readAPIKey() else { throw AnthropicError.missingAPIKey }

        var messages: [[String: Any]] = [["role": "user", "content": content]]
        var result = StreamResult()

        for round in 1...maxRounds {
            result.rounds = round
            let turn = try await streamOnce(
                apiKey: apiKey, system: system, messages: messages,
                tools: tools.values.map(\.definition), effort: effort, onDelta: onDelta
            )
            result.model = turn.model
            result.outputTokens = turn.outputTokens

            guard turn.stopReason == "tool_use", !turn.toolUses.isEmpty else { break }

            // Echo the assistant turn back verbatim — including thinking blocks,
            // which must be replayed unchanged on the same model.
            messages.append(["role": "assistant", "content": turn.assistantContent])

            // All results from one assistant turn go back in a single user message;
            // splitting them teaches the model to stop calling tools in parallel.
            let results: [[String: Any]] = turn.toolUses.map { use in
                let output = tools[use.name]?.handler(use.input) ?? "No such tool: \(use.name)"
                return ["type": "tool_result", "tool_use_id": use.id, "content": output]
            }
            messages.append(["role": "user", "content": results])
        }

        return result
    }

    // MARK: - One request

    private struct ToolUse {
        let id: String
        let name: String
        let input: [String: Any]
    }

    private struct Turn {
        var model = AnthropicClient.model
        var outputTokens: Int?
        var stopReason: String?
        var assistantContent: [[String: Any]] = []
        var toolUses: [ToolUse] = []
    }

    private static func streamOnce(
        apiKey: String,
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        effort: Effort,
        onDelta: (String) -> Void
    ) async throws -> Turn {

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "stream": true,
            // If Opus 5's classifiers decline, Anthropic re-runs server-side on a
            // suitable model rather than handing back a refusal.
            "fallbacks": "default",
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": effort.rawValue],
            "system": system,
            "messages": messages
        ]
        if !tools.isEmpty { body["tools"] = tools }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw AnthropicError.transport("No internet connection.")
        } catch {
            throw AnthropicError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            throw AnthropicError.http(status: status, message: errorMessage(fromBody: raw))
        }

        var turn = Turn()
        // Blocks are assembled by index, because the stream interleaves them.
        var blocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }

            switch type {
            case "message_start":
                if let message = event["message"] as? [String: Any],
                   let served = message["model"] as? String {
                    turn.model = served
                }

            case "content_block_start":
                if let index = event["index"] as? Int,
                   let block = event["content_block"] as? [String: Any] {
                    blocks[index] = block
                }

            case "content_block_delta":
                guard let index = event["index"] as? Int,
                      let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String
                else { break }

                switch deltaType {
                case "text_delta":
                    if let text = delta["text"] as? String, !text.isEmpty {
                        let existing = blocks[index]?["text"] as? String ?? ""
                        blocks[index]?["text"] = existing + text
                        onDelta(text)
                    }
                case "thinking_delta":
                    if let thought = delta["thinking"] as? String {
                        let existing = blocks[index]?["thinking"] as? String ?? ""
                        blocks[index]?["thinking"] = existing + thought
                    }
                case "signature_delta":
                    if let signature = delta["signature"] as? String {
                        blocks[index]?["signature"] = signature
                    }
                case "input_json_delta":
                    if let fragment = delta["partial_json"] as? String {
                        partialJSON[index] = (partialJSON[index] ?? "") + fragment
                    }
                default:
                    break
                }

            case "content_block_stop":
                if let index = event["index"] as? Int,
                   blocks[index]?["type"] as? String == "tool_use" {
                    let raw = partialJSON[index] ?? "{}"
                    let parsed = (try? JSONSerialization.jsonObject(
                        with: Data((raw.isEmpty ? "{}" : raw).utf8)
                    )) as? [String: Any] ?? [:]
                    blocks[index]?["input"] = parsed
                }

            case "message_delta":
                if let usage = event["usage"] as? [String: Any],
                   let tokens = usage["output_tokens"] as? Int {
                    turn.outputTokens = tokens
                }
                if let delta = event["delta"] as? [String: Any] {
                    turn.stopReason = delta["stop_reason"] as? String
                    if turn.stopReason == "refusal" {
                        let details = delta["stop_details"] as? [String: Any]
                        throw AnthropicError.refusal(details?["explanation"] as? String ?? "")
                    }
                }

            case "error":
                let error = event["error"] as? [String: Any]
                throw AnthropicError.transport(error?["message"] as? String ?? "The stream failed.")

            default:
                break
            }
        }

        // Rebuild the assistant turn in wire order, dropping empty text blocks
        // (the API rejects them on replay).
        for index in blocks.keys.sorted() {
            guard var block = blocks[index] else { continue }
            let blockType = block["type"] as? String
            if blockType == "text", (block["text"] as? String ?? "").isEmpty { continue }
            if blockType == "tool_use" {
                if block["input"] == nil { block["input"] = [String: Any]() }
                if let id = block["id"] as? String, let name = block["name"] as? String {
                    turn.toolUses.append(
                        ToolUse(id: id, name: name, input: block["input"] as? [String: Any] ?? [:])
                    )
                }
            }
            turn.assistantContent.append(block)
        }

        return turn
    }

    private static func errorMessage(fromBody body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return body.isEmpty ? "no response body" : String(body.prefix(300)) }
        return message
    }
}
