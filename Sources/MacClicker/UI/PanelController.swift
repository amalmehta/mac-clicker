import AppKit
import SwiftUI

/// A borderless panel that can still take keyboard focus, so the answer is
/// scrollable and selectable and `esc` dismisses it.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let overlay = AnnotationOverlay()
    let runner: TaskRunner
    var onOpenSettings: (() -> Void)?

    private var panel: KeyPanel?
    private var escapeMonitor: Any?

    init(registry: MCPRegistry) {
        runner = TaskRunner(overlay: overlay, registry: registry)
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// The hotkey action: dismiss if already up, otherwise capture and run.
    func toggle() {
        if isVisible { close() } else { present() }
    }

    /// `question` is set when the run was started by voice, which skips the picker.
    /// `skill` runs one skill directly, as the menu bar items do.
    func present(question: String? = nil, skill: Skill? = nil) {
        // Everything here happens *before* the panel appears, while the user's app is
        // still frontmost — that is what makes reading the selection possible.
        guard Keychain.readAPIKey() != nil else {
            runner.block(.noAPIKey)
            show()
            return
        }
        guard AccessibilityPermission.isTrusted else {
            runner.block(.noAccessibility)
            AccessibilityPermission.request()
            show()
            return
        }

        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let captured = SelectionCapture.capture()
        runner.begin(with: captured, pid: pid, spokenQuestion: question)
        if let skill { runner.run(skill) }
        show()
    }

    /// Voice hotkey: open listening, or send what's been heard so far if already up.
    func toggleVoice() {
        if isVisible, runner.isListening {
            runner.finishListening()
            return
        }
        guard Keychain.readAPIKey() != nil else {
            runner.block(.noAPIKey)
            show()
            return
        }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let captured = AccessibilityPermission.isTrusted ? SelectionCapture.capture() : nil
        runner.beginListening(with: captured, pid: pid)
        show()
    }

    func close() {
        runner.dismiss()
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        panel?.orderOut(nil)
    }

    // MARK: - Window plumbing

    private func show() {
        let panel = panel ?? makePanel()
        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installEscapeMonitor()
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelMetrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // One level above the annotation overlay, so rings never cover the answer.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        let view = PanelView(
            runner: runner,
            onClose: { [weak self] in self?.close() },
            onOpenSettings: { [weak self] in
                self?.close()
                self?.onOpenSettings?()
            }
        )
        panel.contentView = NSHostingView(rootView: view)
        self.panel = panel
        return panel
    }

    /// Just below and to the right of the cursor, nudged back on-screen if the
    /// selection was near an edge.
    private func position(_ panel: KeyPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let margin: CGFloat = 12
        var origin = CGPoint(x: mouse.x + 16, y: mouse.y - PanelMetrics.height - 16)
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - PanelMetrics.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - PanelMetrics.height - margin)
        panel.setFrameOrigin(origin)
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53: // esc
                self?.close()
                return nil
            case 36 where self?.runner.isListening == true: // return, while listening
                self?.runner.finishListening()
                return nil
            default:
                return event
            }
        }
    }

    // Clicking away dismisses, the way a spotlight-style panel should — unless the
    // user has pinned it. Auto-closing also makes an answer impossible to screenshot
    // or to read beside another window, which is why the pin exists.
    func windowDidResignKey(_ notification: Notification) {
        guard !Settings.keepPanelOpen else { return }
        close()
    }
}
