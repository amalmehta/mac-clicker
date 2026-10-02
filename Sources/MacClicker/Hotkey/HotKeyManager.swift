import Carbon.HIToolbox
import Foundation

/// Registers a system-wide hotkey through Carbon's hotkey API.
///
/// This deliberately avoids a CGEvent tap: Carbon hotkeys need no Accessibility
/// permission, cannot drop other apps' keystrokes, and are released cleanly when
/// the app quits.
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onPress: (() -> Void)?

    private static let signature: OSType = 0x504D4331 // 'PMC1'

    /// Replaces any previously registered hotkey. Returns false if the combination
    /// is already claimed by another app.
    @discardableResult
    func register(preset: HotKeyPreset, onPress: @escaping () -> Void) -> Bool {
        unregister()
        self.onPress = onPress
        installHandlerIfNeeded()

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            preset.keyCode, preset.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.onPress?()
                return noErr
            },
            1, &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    deinit { unregister() }
}
