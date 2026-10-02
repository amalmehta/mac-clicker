import AppKit
import CoreAudio

/// "Is this a bad moment to speak up?"
///
/// The reliable public signal is whether any process is running the default audio
/// input device — true on every call, huddle, or recording. Hey Clicky arrived at
/// the same rule the hard way: unprompted output during a call is the fastest way
/// to get an app uninstalled.
enum Presence {

    static var isMicrophoneInUse: Bool {
        guard let device = defaultInputDevice else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    /// True when the app should suppress anything the user did not explicitly ask
    /// for. Things they *did* ask for are never suppressed.
    static var shouldStayQuiet: Bool { Settings.quietOnCalls && isMicrophoneInUse }

    private static var defaultInputDevice: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }
}
