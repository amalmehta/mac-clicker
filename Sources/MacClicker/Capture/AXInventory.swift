import AppKit
import ApplicationServices

/// One addressable thing on screen: a button, a field, a tab, a label.
struct AXElement: Identifiable {
    let id: String
    let role: String
    let label: String
    /// Cocoa screen coordinates (bottom-left origin), ready to draw into.
    let frame: CGRect
    let element: AXUIElement

    /// Re-reads the live frame, so an annotation can follow a window that moves.
    var currentFrame: CGRect? { AXInventory.frame(of: element) }
}

/// Builds the list of on-screen elements a model can point at *by name*.
///
/// This is the whole trick behind accurate annotation. Asking a vision model for
/// pixel coordinates is unreliable — it is good at "the Quantize button" and bad at
/// "(842, 511)". So we enumerate the real elements, let the model choose one by id,
/// and take the geometry from the accessibility tree instead of from the model.
enum AXInventory {

    /// Roles worth offering. Interactive things, plus short labels that are often
    /// the thing someone actually needs pointed out.
    private static let interesting: Set<String> = [
        kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXCheckBoxRole,
        kAXRadioButtonRole, kAXSliderRole, kAXIncrementorRole, kAXTextFieldRole,
        kAXTextAreaRole, kAXComboBoxRole, kAXTabGroupRole, kAXToolbarRole,
        kAXMenuItemRole, kAXCellRole, kAXRowRole, kAXDisclosureTriangleRole,
        kAXStaticTextRole, kAXImageRole,
        // Not exported as constants by the SDK:
        "AXLink", "AXSegmentedControl", "AXRadioGroup"
    ]

    static func inventory(for pid: pid_t, limit: Int = 110) -> [AXElement] {
        guard AccessibilityPermission.isTrusted else { return [] }

        let app = AXUIElementCreateApplication(pid)
        // Start from the focused window when there is one: it keeps the list small
        // and relevant instead of enumerating every palette the app owns.
        let roots: [AXUIElement] = {
            if let focused: AXUIElement = attribute(app, kAXFocusedWindowAttribute) {
                return [focused]
            }
            if let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) {
                return Array(windows.prefix(2))
            }
            return [app]
        }()

        var found: [AXElement] = []
        var queue = roots
        var visited = 0
        let visitCap = 4_000 // deep trees (web views) would otherwise walk forever

        while !queue.isEmpty, found.count < limit, visited < visitCap {
            let element = queue.removeFirst()
            visited += 1

            if let candidate = describe(element, index: found.count) {
                found.append(candidate)
            }
            if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
                queue.append(contentsOf: children)
            }
        }
        return found
    }

    /// The compact listing handed to the model.
    static func listing(_ elements: [AXElement]) -> String {
        elements.map { element in
            let size = "\(Int(element.frame.width))×\(Int(element.frame.height))"
            return "\(element.id)  \(short(element.role))  \"\(element.label)\"  [\(size)]"
        }
        .joined(separator: "\n")
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute)
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }

        return flipToCocoa(CGRect(origin: point, size: size))
    }

    // MARK: - Element description

    private static func describe(_ element: AXUIElement, index: Int) -> AXElement? {
        guard let role: String = attribute(element, kAXRoleAttribute),
              interesting.contains(role)
        else { return nil }

        guard let frame = frame(of: element),
              frame.width >= 8, frame.height >= 8,
              frame.width < 4_000, frame.height < 3_000,
              isOnScreen(frame)
        else { return nil }

        guard let label = bestLabel(element, role: role) else { return nil }

        return AXElement(
            id: "e\(index + 1)", role: role, label: label, frame: frame, element: element
        )
    }

    private static func bestLabel(_ element: AXUIElement, role: String) -> String? {
        let candidates: [String?] = [
            attribute(element, kAXTitleAttribute),
            attribute(element, kAXDescriptionAttribute),
            attribute(element, kAXValueAttribute) as String?,
            attribute(element, kAXHelpAttribute),
            attribute(element, kAXRoleDescriptionAttribute)
        ]
        for case let text? in candidates {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // A whole paragraph of body text isn't a label worth pointing at.
            guard trimmed.count <= 60 else {
                return role == kAXStaticTextRole ? nil : String(trimmed.prefix(60)) + "…"
            }
            return trimmed
        }
        return nil
    }

    private static func isOnScreen(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    /// The accessibility API measures from the top-left of the primary display and
    /// grows downward; AppKit measures from the bottom-left and grows upward.
    /// Getting this backwards is the classic reason annotations land in the wrong
    /// place, so it lives in exactly one function.
    private static func flipToCocoa(_ rect: CGRect) -> CGRect {
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main)?.frame.height ?? 0
        return CGRect(
            x: rect.minX, y: primaryHeight - rect.maxY,
            width: rect.width, height: rect.height
        )
    }

    private static func short(_ role: String) -> String {
        role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }

    // MARK: - Typed attribute access

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value
        else { return nil }
        return value as? T
    }
}
