import AppKit
import SwiftUI

/// One thing being pointed at on screen.
struct Annotation: Identifiable {
    let id = UUID()
    /// Step number, for multi-step instructions.
    let step: Int
    let label: String
    /// Cocoa screen coordinates.
    var frame: CGRect
    /// Kept so the ring can follow the element if its window moves or scrolls.
    let element: AXUIElement?
}

/// A window that is allowed to cover the whole screen.
///
/// AppKit otherwise runs every window frame through `constrainFrameRect`, which
/// nudges it down so it cannot sit under the menu bar. For an overlay sized to the
/// full screen that shifts the canvas by the menu bar's height, and every ring drawn
/// into it lands that far off.
private final class OverlayWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Draws rings and labels over other apps' windows.
///
/// Two details matter more than the drawing itself:
///
///  * `sharingType = .none` keeps this window out of every screen capture. Hey
///    Clicky shipped an overlay without it, which made window screenshots and
///    Loom/Zoom window shares come out black, and they withdrew the feature in
///    v1.0.52. One property avoids the whole failure mode.
///  * `ignoresMouseEvents = true` means the overlay is never in the user's way —
///    clicks pass straight through to the app underneath.
@MainActor
final class AnnotationOverlay {

    private var windows: [NSWindow] = []
    /// The screen frames the current windows were built for. Rebuilt when they
    /// change, because each canvas bakes in the frame it maps coordinates against.
    private var builtFrames: [CGRect] = []
    private var tracker: Timer?
    private let store = AnnotationStore()

    var isShowing: Bool { !store.annotations.isEmpty }

    func show(_ annotations: [Annotation]) {
        guard Settings.showAnnotations, !annotations.isEmpty else { return }
        store.annotations = annotations
        buildWindowsIfNeeded()
        windows.forEach { $0.orderFront(nil) }
        startTracking()
    }

    func add(_ annotation: Annotation) {
        guard Settings.showAnnotations else { return }
        store.annotations.append(annotation)
        buildWindowsIfNeeded()
        windows.forEach { $0.orderFront(nil) }
        startTracking()
    }

    /// Draws a ring inset exactly 100pt from every edge of each screen, for ten
    /// seconds. If the gaps are not equal on all four sides, the difference is the
    /// geometry error — and which screen it happens on says where it comes from.
    func showAlignmentTest() {
        let marks = NSScreen.screens.enumerated().map { index, screen in
            Annotation(
                step: index + 1,
                label: "100pt from every edge of this screen",
                frame: screen.frame.insetBy(dx: 100, dy: 100),
                element: nil
            )
        }
        store.annotations = marks
        buildWindowsIfNeeded()
        windows.forEach { $0.orderFront(nil) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.clear()
        }
    }

    func clear() {
        stopTracking()
        store.annotations = []
        windows.forEach { $0.orderOut(nil) }
    }

    // MARK: - Windows

    /// One window per screen, covering it entirely. Simpler and more robust than
    /// resizing a single window to the union of the marks.
    private func buildWindowsIfNeeded() {
        let screens = NSScreen.screens
        let frames = screens.map(\.frame)

        // Rebuild outright when anything about the layout changed. Resizing a window
        // whose canvas captured the old frame would silently offset every ring.
        guard frames != builtFrames else { return }

        windows.forEach { $0.orderOut(nil) }
        builtFrames = frames
        windows = screens.map { screen in
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            // Keep the overlay out of screenshots and screen shares.
            window.sharingType = .none

            let hosting = NSHostingView(
                rootView: AnnotationCanvas(store: store, screenFrame: screen.frame)
            )
            // Without this the hosting view insets its content for the safe area —
            // the notch on built-in displays — moving everything drawn inside it.
            hosting.safeAreaRegions = []
            window.contentView = hosting

            window.setFrame(screen.frame, display: false)
            return window
        }
    }

    // MARK: - Following moving windows

    private func startTracking() {
        stopTracking()
        tracker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFrames() }
        }
    }

    private func stopTracking() {
        tracker?.invalidate()
        tracker = nil
    }

    private func refreshFrames() {
        var changed = false
        var updated = store.annotations
        for index in updated.indices {
            guard let element = updated[index].element,
                  let live = AXInventory.frame(of: element),
                  live != updated[index].frame
            else { continue }
            updated[index].frame = live
            changed = true
        }
        if changed { store.annotations = updated }
    }
}

/// Shared observable state so every screen's canvas redraws together.
@MainActor
final class AnnotationStore: ObservableObject {
    @Published var annotations: [Annotation] = []
}

private struct AnnotationCanvas: View {
    @ObservedObject var store: AnnotationStore
    let screenFrame: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(store.annotations) { annotation in
                if let local = localRect(annotation.frame) {
                    Ring(step: annotation.step, label: annotation.label)
                        .frame(width: local.width, height: local.height)
                        .offset(x: local.minX, y: local.minY)
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Screen coordinates (y up, global) → this window's SwiftUI space (y down, local).
    private func localRect(_ rect: CGRect) -> CGRect? {
        guard screenFrame.intersects(rect) else { return nil }
        let padded = rect.insetBy(dx: -6, dy: -6)
        return CGRect(
            x: padded.minX - screenFrame.minX,
            y: screenFrame.maxY - padded.maxY,
            width: padded.width,
            height: padded.height
        )
    }
}

private struct Ring: View {
    let step: Int
    let label: String
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .shadow(color: Color.accentColor.opacity(0.55), radius: pulse ? 9 : 3)
            .overlay(alignment: .topLeading) { badge.offset(x: -9, y: -11) }
            .overlay(alignment: .bottom) { caption.offset(y: 22) }
            .onAppear {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }

    private var badge: some View {
        Text("\(step)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.accentColor))
            .shadow(radius: 2)
    }

    private var caption: some View {
        Text(label)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 240)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.82))
            )
            .shadow(radius: 3)
    }
}
