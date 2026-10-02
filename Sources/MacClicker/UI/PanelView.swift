import SwiftUI

struct PanelView: View {
    @ObservedObject var runner: TaskRunner
    var onClose: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .frame(width: PanelMetrics.width, height: PanelMetrics.height)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: runner.skill?.symbol ?? "cursorarrow.rays")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(runner.skill?.title ?? "Mac Clicker")
                    .font(.system(size: 13, weight: .semibold))
                if let app = runner.sourceApp {
                    Text("from \(app)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch runner.phase {
        case .blocked(let blocker):
            blockedView(blocker)
        case .picking:
            picker
        case .listening:
            listening
        case .gathering, .working, .done, .failed:
            answer
        }
    }

    private var answer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                selectionQuote

                if case .failed(let message) = runner.phase {
                    ErrorCard(message: message)
                }

                if runner.output.isEmpty, runner.isStreaming {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(runner.phase == .gathering
                             ? (runner.skill?.wantsScreenshot == true ? "Looking at your screen…" : "Reading the selection…")
                             : "Thinking…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if !runner.output.isEmpty {
                    MarkdownText(text: runner.output)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                }

                if let request = runner.consent {
                    ConsentCard(
                        request: request,
                        onAllow: { runner.resolveConsent(true) },
                        onDeny: { runner.resolveConsent(false) }
                    )
                }

                if let suggested = runner.suggestion {
                    SuggestionRow(
                        skill: suggested,
                        onAccept: { runner.acceptSuggestion() },
                        onDismiss: { runner.dismissSuggestion() }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var selectionQuote: some View {
        Group {
            if !runner.selection.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: 2)
                    Text(runner.selection)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectionQuote
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text(runner.dictation.isListening ? "Listening…" : "Starting…")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
            }
            Text(runner.dictation.transcript.isEmpty
                 ? "Ask about what you highlighted, or about anything on screen."
                 : runner.dictation.transcript)
                .font(.system(size: 13))
                .foregroundStyle(runner.dictation.transcript.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var picker: some View {
        ScrollView {
            VStack(spacing: 4) {
                selectionQuote
                    .padding(.bottom, 6)
                ForEach(Skill.all) { skill in
                    Button { runner.run(skill) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: skill.symbol)
                                .frame(width: 18)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(skill.title).font(.system(size: 12.5, weight: .medium))
                                Text(skill.subtitle)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if skill.requiresSelection, runner.selection.isEmpty {
                                Text("needs a selection")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                            } else if skill.canPoint {
                                Image(systemName: "scope")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowButtonStyle())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }

    private func blockedView(_ blocker: Blocker) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: blocker.symbol)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(blocker.title).font(.system(size: 13, weight: .semibold))
            Text(blocker.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = blocker.actionTitle {
                Button(action) {
                    switch blocker {
                    case .noAPIKey: onOpenSettings()
                    case .noAccessibility: AccessibilityPermission.request()
                    case .noSelection: onClose()
                    case .noScreenRecording:
                        ScreenCapturePermission.request()
                        ScreenCapturePermission.openSettingsPane()
                    case .noMicrophone:
                        NSWorkspace.shared.open(URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                        )!)
                    case .noOnDeviceSpeech:
                        NSWorkspace.shared.open(URL(
                            string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
                        )!)
                    }
                }
                .controlSize(.regular)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }

    private typealias Blocker = TaskRunner.Blocker

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if runner.consent != nil {
                Text("waiting for you")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                Spacer()
            } else if runner.isListening {
                Text("return to send · esc to cancel")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Send") { runner.finishListening() }
                    .controlSize(.small)
                    .disabled(runner.dictation.transcript.isEmpty)
            } else if runner.isStreaming {
                Text("Streaming…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { runner.cancel() }
                    .controlSize(.small)
            } else {
                Text(statusLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(runner.lookups.isEmpty
                          ? "No connector tools were used."
                          : "Connectors used:\n" + runner.lookups.joined(separator: "\n"))
                Spacer()
                if case .done = runner.phase {
                    Button("Copy") { runner.copyOutput() }.controlSize(.small)
                }
                if runner.skill != nil, !runner.isStreaming {
                    Button("Retry") { runner.retry() }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusLine: String {
        if case .done = runner.phase, let elapsed = runner.elapsed {
            let model = runner.servedBy ?? AnthropicClient.model
            var line = String(format: "%@ · %.1fs", model, elapsed)
            if runner.usedScreenshot { line += " · screen" }
            if runner.pointedAt > 0 {
                line += " · \(runner.pointedAt) ring\(runner.pointedAt == 1 ? "" : "s")"
            }
            if !runner.lookups.isEmpty {
                let count = runner.lookups.count
                line += " · \(count) lookup\(count == 1 ? "" : "s")"
            }
            return line
        }
        return "esc to dismiss"
    }
}

// MARK: - Pieces

enum PanelMetrics {
    static let width: CGFloat = 480
    static let height: CGFloat = 440
}

/// Asks before anything that would change the world outside this app.
///
/// Shown with the arguments the tool was actually called with, because approving
/// "run write_file" without seeing the path is not approving anything.
private struct ConsentCard: View {
    let request: TaskRunner.ConsentRequest
    var onAllow: () -> Void
    var onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12))
                Text(request.summary)
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(request.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))

            HStack(spacing: 8) {
                Spacer()
                Button("Don't", action: onDeny)
                    .controlSize(.small)
                Button("Allow once", action: onAllow)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
}

/// Mentions a skill the user has never tried, once their answer has arrived.
/// Appearing only after the useful part, and at most once a day, is what keeps this
/// from being an advert.
private struct SuggestionRow: View {
    let skill: Skill
    var onAccept: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: skill.symbol)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("Haven\u{2019}t tried \(skill.title) yet")
                    .font(.system(size: 11.5, weight: .medium))
                Text(skill.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button("Try it", action: onAccept)
                .controlSize(.small)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Not interested")
        }
        .padding(9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ErrorCard: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct HoverRowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : 0)))
            )
            .onHover { hovering = $0 }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension TaskRunner.Blocker {
    var symbol: String {
        switch self {
        case .noAPIKey: return "key.horizontal"
        case .noAccessibility: return "hand.raised"
        case .noSelection: return "text.cursor"
        case .noScreenRecording: return "rectangle.on.rectangle.slash"
        case .noMicrophone: return "mic.slash"
        case .noOnDeviceSpeech: return "waveform.slash"
        }
    }
    var title: String {
        switch self {
        case .noAPIKey: return "Add your API key"
        case .noAccessibility: return "Accessibility access needed"
        case .noSelection: return "Nothing highlighted"
        case .noScreenRecording: return "Screen Recording access needed"
        case .noMicrophone: return "Microphone access needed"
        case .noOnDeviceSpeech: return "No on-device speech model"
        }
    }
    var detail: String {
        switch self {
        case .noAPIKey:
            return "Mac Clicker calls the Anthropic API with your own key. Paste one in Settings and it's stored in your login keychain."
        case .noAccessibility:
            return "macOS only lets an app read the text you've highlighted in other apps once you allow it under Privacy & Security → Accessibility."
        case .noSelection:
            return "This skill works on highlighted text. Highlight something and press the hotkey again — or pick \u{201C}What\u{2019}s on screen\u{201D} instead."
        case .noScreenRecording:
            return "Skills that look at your screen need Screen Recording access, which macOS keeps separate from Accessibility. Allow MacClicker under Privacy & Security \u{2192} Screen Recording, then try again."
        case .noMicrophone:
            return "Asking by voice needs the microphone and speech recognition. Transcription runs on this Mac \u{2014} only the resulting text is sent."
        case .noOnDeviceSpeech:
            return "This Mac has no offline speech model for your language, and Mac Clicker will not send your voice to a server to work around that. Turn on Dictation for your language in Keyboard settings; macOS downloads the model, and this starts working."
        }
    }
    var actionTitle: String? {
        switch self {
        case .noAPIKey: return "Open Settings…"
        case .noAccessibility: return "Grant Access…"
        case .noSelection: return nil
        case .noScreenRecording: return "Open Screen Recording…"
        case .noMicrophone: return "Open Microphone Settings…"
        case .noOnDeviceSpeech: return "Open Keyboard Settings…"
        }
    }
}
