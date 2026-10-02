import AppKit
import ApplicationServices

struct CapturedSelection {
    let text: String
    let sourceApp: String?
}

enum AccessibilityPermission {
    /// True when this app is allowed to read other apps' UI and post keystrokes.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt with the "Open System Settings" button.
    @discardableResult
    static func request() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSettingsPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// Reads whatever the user has highlighted in the frontmost app.
///
/// Two strategies, in order:
///  1. The Accessibility API, which reads the selection without touching the
///     pasteboard. Works in native text views (Preview, Xcode, Notes, Mail…).
///  2. A synthesized ⌘C, for apps that expose no AX selection (most notably
///     Chrome and Electron apps). The pasteboard is restored afterwards.
enum SelectionCapture {
    static func capture() -> CapturedSelection? {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName

        if let text = viaAccessibility() {
            return CapturedSelection(text: text, sourceApp: app)
        }
        if let text = viaCopyCommand() {
            return CapturedSelection(text: text, sourceApp: app)
        }
        return nil
    }

    // MARK: - Strategy 1: Accessibility

    private static func viaAccessibility() -> String? {
        guard AccessibilityPermission.isTrusted else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef else { return nil }

        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selectedRef
        ) == .success else { return nil }

        return normalized(selectedRef as? String)
    }

    // MARK: - Strategy 2: synthesized ⌘C

    private static let cKeyCode: CGKeyCode = 0x08

    private static func viaCopyCommand() -> String? {
        guard AccessibilityPermission.isTrusted else { return nil }

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let changeCountBefore = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
        else { return nil }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // Give the frontmost app a moment to service the copy. Polling keeps the
        // common case fast instead of always paying a fixed delay.
        var copied: String?
        let deadline = Date().addingTimeInterval(0.45)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if pasteboard.changeCount != changeCountBefore {
                copied = pasteboard.string(forType: .string)
                break
            }
        }

        // Put the user's clipboard back the way we found it.
        if copied != nil {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }

        return normalized(copied)
    }

    // MARK: - Helpers

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Guard against a runaway select-all on a huge document.
        let limit = 60_000
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n\n[selection truncated]"
    }
}
