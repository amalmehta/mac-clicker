import AppKit
import MacClickerKit
import SwiftUI

/// Drives one run of one skill: gathers only the context that skill asks for,
/// streams the answer, and turns the model's `point_at` calls into rings on screen.
@MainActor
final class TaskRunner: ObservableObject {

    enum Phase: Equatable {
        case picking
        case listening
        case gathering
        case working
        case done
        case failed(String)
        case blocked(Blocker)
    }

    enum Blocker: Equatable {
        case noAPIKey
        case noAccessibility
        case noSelection
        case noScreenRecording
        case noMicrophone
        case noOnDeviceSpeech
    }

    @Published private(set) var phase: Phase = .picking
    @Published private(set) var skill: Skill?
    @Published private(set) var selection: String = ""
    @Published private(set) var sourceApp: String?
    @Published private(set) var question: String?
    @Published private(set) var output: String = ""
    @Published private(set) var servedBy: String?
    @Published private(set) var elapsed: TimeInterval?
    @Published private(set) var pointedAt: Int = 0
    @Published private(set) var usedScreenshot = false
    /// Connector tools called during this run, in order, as "server/tool".
    @Published private(set) var lookups: [String] = []
    /// A skill the user has never tried, offered once an answer has landed. Nil
    /// whenever the backoff says now is not a good moment.
    @Published private(set) var suggestion: Skill?

    let dictation = Dictation()

    /// A pending request for the user to approve something that would change the
    /// world. The model's tool call is suspended until this resolves.
    struct ConsentRequest: Identifiable, Equatable {
        let id = UUID()
        let summary: String
        let detail: String
    }

    @Published private(set) var consent: ConsentRequest?
    private var consentContinuation: CheckedContinuation<Bool, Never>?

    private let overlay: AnnotationOverlay
    private let registry: MCPRegistry
    private var sourcePID: pid_t?
    private var elements: [AXElement] = []
    private var task: Task<Void, Never>?
    private var pending = ""
    private var lastFlush: CFTimeInterval = 0

    init(overlay: AnnotationOverlay, registry: MCPRegistry) {
        self.overlay = overlay
        self.registry = registry
    }

    // MARK: - Consent

    /// Suspends a tool call until the user answers. Resolved exactly once: by a
    /// button, or by the run being cancelled, which counts as no.
    private func askConsent(summary: String, detail: String) async -> Bool {
        await withCheckedContinuation { continuation in
            consent = ConsentRequest(summary: summary, detail: detail)
            consentContinuation = continuation
        }
    }

    func resolveConsent(_ allowed: Bool) {
        guard let continuation = consentContinuation else { return }
        consentContinuation = nil
        consent = nil
        continuation.resume(returning: allowed)
    }

    var isStreaming: Bool { phase == .working || phase == .gathering }
    var isListening: Bool { phase == .listening }

    // MARK: - Voice

    /// Opens straight into listening. The selection and app are captured before the
    /// panel appears, exactly as for a typed run.
    func beginListening(with captured: CapturedSelection?, pid: pid_t?) {
        cancel()
        reset()
        selection = captured?.text ?? ""
        sourceApp = captured?.sourceApp
        sourcePID = pid
        skill = Skill.ask
        phase = .listening

        Task { @MainActor in
            var allowed = Dictation.isAuthorized
            if !allowed { allowed = await Dictation.requestPermissions() }
            guard allowed else {
                self.phase = .blocked(.noMicrophone)
                return
            }
            guard self.phase == .listening else { return }

            // Checked before the microphone opens, so nothing is recorded that would
            // then have to be sent away to be understood.
            guard self.dictation.isOnDeviceAvailable else {
                self.phase = .blocked(.noOnDeviceSpeech)
                return
            }

            self.dictation.start()
            if let problem = self.dictation.errorMessage {
                self.phase = .failed(problem)
            }
        }
    }

    /// Stops the microphone and answers what was heard.
    func finishListening() {
        guard phase == .listening else { return }
        let heard = dictation.stop()
        guard !heard.isEmpty else {
            phase = .picking
            return
        }
        question = heard
        run(.ask)
    }

    // MARK: - Entry points

    func block(_ blocker: Blocker) {
        cancel()
        skill = nil
        reset()
        phase = .blocked(blocker)
    }

    /// Loads a fresh capture. Runs the only skill directly, or shows the picker.
    func begin(with captured: CapturedSelection?, pid: pid_t?, spokenQuestion: String? = nil) {
        cancel()
        reset()
        selection = captured?.text ?? ""
        sourceApp = captured?.sourceApp
        sourcePID = pid
        question = spokenQuestion

        // A dictated question is already a request — skip the menu and answer it.
        if let spokenQuestion, !spokenQuestion.isEmpty {
            run(.ask)
            return
        }
        if Skill.all.count == 1, let only = Skill.all.first {
            run(only)
        } else {
            skill = nil
            phase = .picking
        }
    }

    func run(_ skill: Skill) {
        cancel()
        self.skill = skill
        output = ""
        pending = ""
        servedBy = nil
        elapsed = nil
        pointedAt = 0
        usedScreenshot = false
        lookups = []
        overlay.clear()

        if skill.requiresSelection, selection.isEmpty {
            phase = .blocked(.noSelection)
            return
        }
        if skill.wantsScreenshot, !ScreenCapturePermission.isGranted {
            phase = .blocked(.noScreenRecording)
            ScreenCapturePermission.request()
            return
        }

        suggestion = nil
        Suggestions.recordUse(of: skill)

        phase = .gathering
        let started = CACurrentMediaTime()
        lastFlush = started

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let content = await self.gather(for: skill)
                guard !Task.isCancelled else { return }
                self.phase = .working

                var tools: [String: AnthropicClient.Tool] = [:]
                if skill.canPoint { tools[Self.pointToolName] = self.pointTool() }
                if skill.usesConnectors {
                    let connectorTools = self.registry.tools(
                        consent: { summary, detail in
                            await self.askConsent(summary: summary, detail: detail)
                        },
                        didCall: { [weak self] name in self?.lookups.append(name) }
                    )
                    tools.merge(connectorTools) { existing, _ in existing }
                }

                // Only describe the connectors when there are some; a prompt that
                // promises tools the model cannot see makes it apologise for their
                // absence.
                let system = tools.count > (skill.canPoint ? 1 : 0)
                    ? skill.system + "\n" + Skill.connectorGuidance
                    : skill.system

                let result = try await AnthropicClient.run(
                    system: system,
                    content: content,
                    tools: tools,
                    effort: Settings.effort,
                    onDelta: { [weak self] delta in self?.append(delta) }
                )
                guard !Task.isCancelled else { return }

                self.flush()
                self.servedBy = result.model
                self.elapsed = CACurrentMediaTime() - started
                self.phase = self.output.isEmpty && self.pointedAt == 0
                    ? .failed("Claude returned an empty response. Try again.")
                    : .done
                Announcer.say("Done.", unprompted: true)

                // Only once the user has what they came for, and only if the
                // backoff agrees this is a reasonable moment.
                if self.phase == .done { self.suggestion = Suggestions.offer() }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.flush()
                self.phase = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
    }

    /// The user took the suggestion. Clears every backoff streak.
    func acceptSuggestion() {
        guard let suggested = suggestion else { return }
        Suggestions.resolve(.accepted)
        suggestion = nil
        run(suggested)
    }

    func dismissSuggestion() {
        guard suggestion != nil else { return }
        Suggestions.resolve(.dismissed)
        suggestion = nil
    }

    func retry() {
        if let skill { run(skill) }
    }

    func cancel() {
        // Anything waiting on approval must be released, or the run would hang on a
        // continuation nobody can reach.
        resolveConsent(false)
        task?.cancel()
        task = nil
    }

    func dismiss() {
        cancel()
        dictation.cancel()
        overlay.clear()
    }

    func copyOutput() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }

    // MARK: - Context gathering

    private func gather(for skill: Skill) async -> [[String: Any]] {
        var blocks: [[String: Any]] = []

        if skill.wantsScreenshot,
           let shot = await ScreenCapture.capture(windowOf: sourcePID) {
            blocks.append(UserContent.pngImage(shot.png))
            usedScreenshot = true
        }

        if skill.wantsElements, let pid = sourcePID {
            elements = AXInventory.inventory(for: pid)
        } else {
            elements = []
        }

        let context = SkillContext(
            selection: selection.isEmpty ? nil : selection,
            sourceApp: sourceApp,
            audience: Settings.audience,
            question: question,
            elements: elements.isEmpty ? nil : AXInventory.listing(elements)
        )
        blocks.append(UserContent.text(skill.prompt(context)))
        return blocks
    }

    // MARK: - The point_at tool

    private static let pointToolName = "point_at"

    private func pointTool() -> AnthropicClient.Tool {
        AnthropicClient.Tool(
            definition: [
                "name": Self.pointToolName,
                "description": """
                Draw a numbered ring around one element on the user's real screen so \
                they can see exactly what you mean. Call once per step, in order. The \
                element_id must come from the ELEMENTS list in the prompt.
                """,
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "element_id": [
                            "type": "string",
                            "description": "An id from the ELEMENTS list, e.g. \"e12\"."
                        ],
                        "label": [
                            "type": "string",
                            "description": "Very short imperative label shown under the ring, at most about six words."
                        ]
                    ],
                    "required": ["element_id", "label"],
                    "additionalProperties": false
                ],
                "strict": true
            ],
            handler: { [weak self] input in
                guard let self else { return "Cancelled." }
                guard let id = input["element_id"] as? String,
                      let label = input["label"] as? String
                else { return "Missing element_id or label." }

                // The model is only ever allowed to name an element we found; the
                // geometry comes from the accessibility tree, never from the model.
                guard let element = self.elements.first(where: { $0.id == id }) else {
                    return "No element with id \(id). Use only ids from the ELEMENTS list, or explain that step in words instead."
                }
                let frame = element.currentFrame ?? element.frame
                self.pointedAt += 1
                self.overlay.add(
                    Annotation(
                        step: self.pointedAt, label: label, frame: frame, element: element.element
                    )
                )
                return "Ring \(self.pointedAt) drawn around \(id) (\"\(element.label)\")."
            }
        )
    }

    // MARK: - Delta coalescing

    /// Tokens arrive faster than the panel needs to redraw; batching into ~20 fps
    /// keeps SwiftUI from re-laying out the whole answer per token.
    private func append(_ delta: String) {
        pending += delta
        let now = CACurrentMediaTime()
        if now - lastFlush >= 0.05 {
            flush()
            lastFlush = now
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        output += pending
        pending = ""
    }

    private func reset() {
        selection = ""
        sourceApp = nil
        sourcePID = nil
        question = nil
        output = ""
        servedBy = nil
        elapsed = nil
        pointedAt = 0
        usedScreenshot = false
        lookups = []
        suggestion = nil
        elements = []
        overlay.clear()
    }
}
