import AppKit
import MacClickerKit
import SwiftUI

struct SettingsView: View {
    /// Called when either hotkey changes so the Carbon registrations can be redone.
    var onHotKeysChanged: () -> Void
    /// Draws the alignment test rings.
    var onCheckAlignment: () -> Void

    @State private var apiKeyField = ""
    @State private var hasStoredKey = Keychain.hasStoredItem
    @State private var hotKey = Settings.hotKey
    @State private var voiceHotKey = Settings.voiceHotKey
    @State private var effort = Settings.effort
    @State private var audience = Settings.audience
    @State private var annotate = Settings.showAnnotations
    @State private var speak = Settings.speakAnnouncements
    @State private var quietOnCalls = Settings.quietOnCalls
    @State private var suggestionsOn = Settings.suggestionsEnabled
    @State private var restingUntil: Date?
    @State private var trusted = AccessibilityPermission.isTrusted
    @State private var screenGranted = ScreenCapturePermission.isGranted
    @State private var micGranted = Dictation.isAuthorized
    @State private var saveNote: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    SecureField("sk-ant-…", text: $apiKeyField)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { saveKey() }
                        .disabled(apiKeyField.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: 6) {
                    Image(systemName: hasStoredKey ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(hasStoredKey ? .green : .secondary)
                    Text(saveNote ?? (hasStoredKey
                         ? "A key is stored in your login keychain."
                         : "No key stored yet."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if hasStoredKey {
                        Button("Remove") {
                            Keychain.deleteAPIKey()
                            hasStoredKey = false
                            saveNote = nil
                        }
                        .controlSize(.small)
                    }
                }
                Link("Create a key in the Anthropic Console",
                     destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.system(size: 11))

                if hasStoredKey {
                    VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Button("Re-authorise this build") {
                            let ok = Keychain.reclaimAccess()
                            if ok { Settings.keychainOwnerSignature = CodeSignature.current }
                            saveNote = ok
                                ? "Done \u{2014} this build can read the key without a prompt."
                                : "Couldn\u{2019}t rewrite the stored key. Paste it again and press Save."
                        }
                        .controlSize(.small)
                        Spacer()
                    }
                    Text("Press this if macOS keeps asking for your login keychain password. It happens when the app\u{2019}s signature changes, and it asks once more before it stops.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Anthropic API key")
            } footer: {
                Text("Requests go straight from this Mac to api.anthropic.com. The key is stored so only this app can read it; anything else has to ask you. If macOS starts asking for your login password, the app\u{2019}s signature changed \u{2014} use Re-authorise this build.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Section("Hotkeys") {
                Picker("Open the panel", selection: $hotKey) {
                    ForEach(HotKeyPreset.all) { preset in Text(preset.label).tag(preset) }
                }
                .onChange(of: hotKey) { _, newValue in
                    Settings.hotKey = newValue
                    onHotKeysChanged()
                }

                Picker("Ask by voice", selection: $voiceHotKey) {
                    ForEach(HotKeyPreset.all) { preset in Text(preset.label).tag(preset) }
                }
                .onChange(of: voiceHotKey) { _, newValue in
                    Settings.voiceHotKey = newValue
                    onHotKeysChanged()
                }

                if hotKey.id == voiceHotKey.id {
                    Label("Both shortcuts are the same — only the panel will open.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            Section("Answers") {
                Picker("Depth", selection: $effort) {
                    ForEach(Effort.allCases) { level in Text(level.label).tag(level) }
                }
                .onChange(of: effort) { _, newValue in Settings.effort = newValue }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Explain things for…").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("", text: $audience, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...3)
                        .onChange(of: audience) { _, newValue in Settings.audience = newValue }
                }
            }

            Section {
                Toggle("Draw on screen to point things out", isOn: $annotate)
                    .onChange(of: annotate) { _, newValue in Settings.showAnnotations = newValue }
                Toggle("Speak status out loud", isOn: $speak)
                    .onChange(of: speak) { _, newValue in Settings.speakAnnouncements = newValue }
                Toggle("Stay quiet while the microphone is in use", isOn: $quietOnCalls)
                    .onChange(of: quietOnCalls) { _, newValue in Settings.quietOnCalls = newValue }
                Toggle("Suggest skills I haven\u{2019}t tried", isOn: $suggestionsOn)
                    .onChange(of: suggestionsOn) { _, newValue in Settings.suggestionsEnabled = newValue }

                if suggestionsOn, let restingUntil {
                    Text("Resting until \(restingUntil.formatted(date: .abbreviated, time: .shortened)) \u{2014} dismissed or ignored too often.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Behaviour")
            } footer: {
                Text("Anything you explicitly ask for always runs; these settings only govern unprompted output. Suggestions appear at most once a day, after an answer rather than before it, and back off on their own if you keep dismissing or ignoring them.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 6) {
                    Button("Check ring alignment") { onCheckAlignment() }
                        .controlSize(.small)
                    Spacer()
                }
                Text("Draws a ring 100pt inside every edge of each screen for ten seconds. Equal gaps on all four sides means the geometry is right; an uneven gap is the error, and which screen shows it says where it comes from.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Troubleshooting")
            }

            Section {
                permissionRow(
                    granted: trusted,
                    label: trusted ? "Accessibility granted." : "Accessibility — required to read highlighted text.",
                    action: {
                        if !trusted { AccessibilityPermission.request() }
                        trusted = AccessibilityPermission.isTrusted
                        if !trusted { AccessibilityPermission.openSettingsPane() }
                    }
                )
                permissionRow(
                    granted: screenGranted,
                    label: screenGranted ? "Screen Recording granted." : "Screen Recording — for skills that look at your screen.",
                    action: {
                        ScreenCapturePermission.request()
                        screenGranted = ScreenCapturePermission.isGranted
                        if !screenGranted { ScreenCapturePermission.openSettingsPane() }
                    }
                )
                permissionRow(
                    granted: micGranted,
                    label: micGranted ? "Microphone and speech granted." : "Microphone — for asking by voice.",
                    action: {
                        Task { @MainActor in
                            _ = await Dictation.requestPermissions()
                            micGranted = Dictation.isAuthorized
                        }
                    }
                )
            } header: {
                Text("Permissions")
            } footer: {
                Text("Dictation is transcribed on this Mac. Only the resulting text is sent with your request.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 470, height: 660)
        .onAppear(perform: refresh)
    }

    private func permissionRow(granted: Bool, label: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(label).font(.system(size: 11))
            Spacer()
            Button(granted ? "Re-check" : "Grant…", action: action)
                .controlSize(.small)
        }
    }

    private func refresh() {
        hasStoredKey = Keychain.hasStoredItem
        trusted = AccessibilityPermission.isTrusted
        screenGranted = ScreenCapturePermission.isGranted
        micGranted = Dictation.isAuthorized
        restingUntil = Suggestions.nextAllowed()
    }

    private func saveKey() {
        if Keychain.writeAPIKey(apiKeyField) {
            apiKeyField = ""
            hasStoredKey = true
            saveNote = "Key saved."
        } else {
            saveNote = "Could not write to the keychain."
        }
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    var onHotKeysChanged: (() -> Void)?
    var onCheckAlignment: (() -> Void)?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(
            onHotKeysChanged: { [weak self] in self?.onHotKeysChanged?() },
            onCheckAlignment: { [weak self] in self?.onCheckAlignment?() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 660),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Clicker Settings"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
