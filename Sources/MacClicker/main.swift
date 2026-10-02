import AppKit

// A menu bar utility: no Dock icon, no main window, no menu bar of its own.
// Top-level code here already runs on the main thread; `assumeIsolated` just
// tells the compiler so.
let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
