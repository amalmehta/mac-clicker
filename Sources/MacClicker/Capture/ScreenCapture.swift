import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenCapturePermission {
    /// Screen Recording is a second TCC grant, separate from Accessibility.
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettingsPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}

/// Grabs what the user is looking at, so a skill can reason about pixels instead of
/// text. Prefers the frontmost window of the target app over the whole display —
/// a tighter crop means fewer vision tokens and less irrelevant context.
enum ScreenCapture {

    /// Longest edge of the image we send. Enough for UI text to stay legible,
    /// small enough to keep the request cheap.
    private static let maxDimension: CGFloat = 1400

    struct Shot {
        let png: Data
        /// Screen rect (Cocoa coordinates) the image covers, so annotation
        /// coordinates can be related back to it.
        let screenRect: CGRect
        let isSingleWindow: Bool
    }

    static func capture(windowOf pid: pid_t?) async -> Shot? {
        guard ScreenCapturePermission.isGranted else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )

            // Our own panel and overlay must never appear in the shot.
            let ownPID = ProcessInfo.processInfo.processIdentifier

            if let pid,
               let window = content.windows
                .filter({ $0.owningApplication?.processID == pid && $0.owningApplication?.processID != ownPID })
                .filter({ $0.frame.width > 120 && $0.frame.height > 120 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {

                let filter = SCContentFilter(desktopIndependentWindow: window)
                if let png = try await image(filter: filter, size: window.frame.size) {
                    return Shot(png: png, screenRect: flipToCocoa(window.frame), isSingleWindow: true)
                }
            }

            // Fall back to the display the pointer is on, minus our own windows.
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            guard let display = content.displays.first(where: { display in
                guard let screen else { return true }
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? CGDirectDisplayID
                return number == nil || display.displayID == number
            }) ?? content.displays.first else { return nil }

            let ours = content.applications.filter { $0.processID == ownPID }
            let filter = SCContentFilter(
                display: display, excludingApplications: ours, exceptingWindows: []
            )
            let size = CGSize(width: display.width, height: display.height)
            guard let png = try await image(filter: filter, size: size) else { return nil }
            return Shot(
                png: png,
                screenRect: screen?.frame ?? CGRect(origin: .zero, size: size),
                isSingleWindow: false
            )
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private static func image(filter: SCContentFilter, size: CGSize) async throws -> Data? {
        let scale = min(1, maxDimension / max(size.width, size.height))
        let config = SCStreamConfiguration()
        config.width = Int((size.width * scale).rounded())
        config.height = Int((size.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
        return png(from: cgImage)
    }

    private static func png(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])
    }

    /// ScreenCaptureKit reports frames with a top-left origin; AppKit wants
    /// bottom-left, measured from the primary display.
    private static func flipToCocoa(_ rect: CGRect) -> CGRect {
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main)?.frame.height ?? rect.maxY
        return CGRect(
            x: rect.minX, y: primaryHeight - rect.maxY,
            width: rect.width, height: rect.height
        )
    }
}
