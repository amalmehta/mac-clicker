import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let mainHotKey = HotKeyManager()
    private let voiceHotKey = HotKeyManager()
    private let registry = MCPRegistry()
    /// Whether each shortcut is actually claimed. A shortcut the system refused is
    /// worse than none at all if the menu keeps advertising it.
    private let health = AppHealth()
    private var mainHotKeyLive = false { didSet { health.mainHotKeyLive = mainHotKeyLive } }
    private var voiceHotKeyLive = false { didSet { health.voiceHotKeyLive = voiceHotKeyLive } }
    private lazy var panel = PanelController(registry: registry)
    private let settings = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.onOpenSettings = { [weak self] in self?.settings.show() }
        settings.onHotKeysChanged = { [weak self] in self?.registerHotKeys(announceFailures: true) }
        settings.onCheckAlignment = { [weak self] in self?.panel.overlay.showAlignmentTest() }

        buildStatusItem()
        registerHotKeys(announceFailures: false)

        // A shortcut is most often refused because the previous instance has not
        // finished exiting. Retrying beats telling the user their shortcut is taken
        // when it will be free in half a second.
        if !mainHotKeyLive || !voiceHotKeyLive {
            Task { @MainActor in
                for delay in [0.5, 1.5, 3.0] {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    registerHotKeys(announceFailures: false)
                    if mainHotKeyLive, voiceHotKeyLive { return }
                }
            }
        }

        reclaimKeychainIfSignatureChanged()

        settings.registry = registry
        settings.health = health
        settings.onRetryShortcuts = { [weak self] in self?.registerHotKeys(announceFailures: true) }
        // Servers start in the background: a config that fetches a package should
        // not hold up the menu bar icon appearing.
        Task { await registry.reload() }

        // First run: nothing works without a key and Accessibility access, so open
        // Settings rather than leaving a silent menu bar icon.
        if Keychain.readAPIKey() == nil || !AccessibilityPermission.isTrusted {
            settings.show()
            AccessibilityPermission.request()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainHotKey.unregister()
        voiceHotKey.unregister()
        registry.shutdown()
    }

    /// The keychain item is readable only by the binary that created it. When the
    /// signature changes — a new signing identity, or an ad-hoc rebuild — macOS stops
    /// recognising us and asks for the login password on every read. Recreating the
    /// item once restores silent access.
    private func reclaimKeychainIfSignatureChanged() {
        let signature = CodeSignature.current
        guard Settings.keychainOwnerSignature != signature else { return }
        guard Keychain.readAPIKey() != nil else { return }

        if Keychain.reclaimAccess() {
            Settings.keychainOwnerSignature = signature
        }
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Mac Clicker"
        )
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        statusItem = item
        refreshShortcutHints()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // One entry per registered skill, so every skill is reachable without the
        // picker. Tags index into Skill.all.
        for (index, skill) in Skill.all.enumerated() {
            let item = NSMenuItem(title: skill.title, action: #selector(runSkill(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = NSImage(systemSymbolName: skill.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let voice = NSMenuItem(title: "Ask by Voice", action: #selector(askByVoice), keyEquivalent: "")
        voice.target = self
        voice.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        menu.addItem(voice)

        let retry = NSMenuItem(
            title: "Retry Shortcuts", action: #selector(retryShortcuts), keyEquivalent: ""
        )
        retry.target = self
        retry.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        retry.isHidden = true
        menu.addItem(retry)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quit = NSMenuItem(title: "Quit Mac Clicker", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    /// Keeps the menu labels in sync with whichever hotkeys are configured.
    private func refreshShortcutHints() {
        guard let items = statusItem?.menu?.items else { return }

        for (index, skill) in Skill.all.enumerated() where index < items.count {
            items[index].title = index == 0
                ? "\(skill.title)\(hint(Settings.hotKey.label, live: mainHotKeyLive))"
                : skill.title
        }
        items.first { $0.action == #selector(askByVoice) }?
            .title = "Ask by Voice\(hint(Settings.voiceHotKey.label, live: voiceHotKeyLive))"

        // A visible repair, rather than a shortcut that quietly does nothing.
        let retry = items.first { $0.action == #selector(retryShortcuts) }
        retry?.isHidden = mainHotKeyLive && voiceHotKeyLive

        statusItem?.button?.image = NSImage(
            systemSymbolName: needsAttention ? "exclamationmark.triangle" : "cursorarrow.rays",
            accessibilityDescription: needsAttention ? "Mac Clicker needs attention" : "Mac Clicker"
        )
        statusItem?.button?.image?.isTemplate = true
    }

    private func hint(_ label: String, live: Bool) -> String {
        live ? "  (\(label))" : "  (shortcut unavailable)"
    }

    /// Anything that stops the app working, worth showing on the menu bar icon.
    private var needsAttention: Bool {
        !mainHotKeyLive
            || !AccessibilityPermission.isTrusted
            || !Keychain.hasStoredItem
    }

    @objc private func retryShortcuts() {
        registerHotKeys(announceFailures: true)
    }

    // MARK: - Actions

    @objc private func runSkill(_ sender: NSMenuItem) {
        guard Skill.all.indices.contains(sender.tag) else { return }
        panel.present(skill: Skill.all[sender.tag])
    }

    @objc private func askByVoice() { panel.toggleVoice() }
    @objc private func openSettings() { settings.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func registerHotKeys(announceFailures: Bool) {
        var taken: [String] = []

        let main = Settings.hotKey
        mainHotKeyLive = mainHotKey.register(preset: main, onPress: { [weak self] in
            self?.panel.toggle()
        })
        if !mainHotKeyLive { taken.append(main.label) }

        let voice = Settings.voiceHotKey
        if voice.id == main.id {
            voiceHotKeyLive = false
            taken.append("\(voice.label) (used twice)")
        } else {
            voiceHotKeyLive = voiceHotKey.register(preset: voice, onPress: { [weak self] in
                self?.panel.toggleVoice()
            })
            if !voiceHotKeyLive { taken.append(voice.label) }
        }

        refreshShortcutHints()

        health.lastHotKeyError = taken.isEmpty ? nil : "unavailable: \(taken.joined(separator: ", "))"

        guard announceFailures, !taken.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = taken.count == 1
            ? "\(taken[0]) is unavailable"
            : "Some shortcuts are unavailable"
        alert.informativeText = """
        Couldn\u{2019}t claim: \(taken.joined(separator: ", ")). \
        Another app may already use it, or both shortcuts are set to the same keys. \
        Pick different ones in Settings.
        """
        alert.alertStyle = .warning
        alert.runModal()
    }
}
