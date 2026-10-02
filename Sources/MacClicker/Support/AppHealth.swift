import AppKit
import Foundation

/// Live state that is worth knowing when something is not working.
///
/// Exists because this app spent a long time failing invisibly: a shortcut that
/// never registered, a keychain item no build could read, a server that had exited.
/// Every one of those was diagnosable only by attaching to the process from outside.
/// None of them should have been.
@MainActor
final class AppHealth: ObservableObject {
    @Published var mainHotKeyLive = false
    @Published var voiceHotKeyLive = false
    /// Set when hotkey registration has been retried and still failed.
    @Published var lastHotKeyError: String?

    /// A plain-text report, for pasting into a bug report or a message to yourself
    /// three weeks from now.
    func summary(registry: MCPRegistry) -> String {
        let bundle = Bundle.main
        var lines: [String] = []

        lines.append("Mac Clicker \(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("")

        lines.append("Shortcuts")
        lines.append("  open panel: \(Settings.hotKey.label) — \(mainHotKeyLive ? "active" : "NOT REGISTERED")")
        lines.append("  ask by voice: \(Settings.voiceHotKey.label) — \(voiceHotKeyLive ? "active" : "NOT REGISTERED")")
        if let lastHotKeyError { lines.append("  last error: \(lastHotKeyError)") }
        lines.append("")

        lines.append("Permissions")
        lines.append("  accessibility: \(AccessibilityPermission.isTrusted ? "granted" : "MISSING")")
        lines.append("  screen recording: \(ScreenCapturePermission.isGranted ? "granted" : "MISSING")")
        lines.append("  microphone + speech: \(Dictation.isAuthorized ? "granted" : "missing")")
        lines.append("")

        lines.append("API key: \(Keychain.hasStoredItem ? "stored" : "NONE")")
        lines.append("Effort: \(Settings.effort.rawValue)")
        lines.append("Panel pinned: \(Settings.keepPanelOpen)")
        lines.append("")

        lines.append("Connectors")
        if !registry.hasConfig {
            lines.append("  none configured")
        } else if let problem = registry.configProblem {
            lines.append("  config problem: \(problem)")
        } else if registry.statuses.isEmpty {
            lines.append("  config has no servers")
        } else {
            for status in registry.statuses {
                lines.append("  \(status.id): \(status.state.plainDescription)"
                    + " — \(status.toolNames.count) offered"
                    + (status.withheldToolNames.isEmpty
                       ? "" : ", \(status.withheldToolNames.count) withheld")
                    + (status.readOnly ? " (read-only)" : ""))
                if !status.diagnostics.isEmpty {
                    lines.append("    stderr: \(status.diagnostics.suffix(200))")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    func copySummary(registry: MCPRegistry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary(registry: registry), forType: .string)
    }
}

extension MCPRegistry.State {
    var plainDescription: String {
        switch self {
        case .ready: return "ready"
        case .starting: return "starting"
        case .disabled: return "disabled"
        case .failed(let reason): return "FAILED (\(reason))"
        }
    }
}
