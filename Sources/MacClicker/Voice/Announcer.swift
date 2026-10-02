import AVFAudio
import Foundation

/// Speaks short status lines. Every call is gated twice: the user's own switch,
/// and whether they're on a call right now.
@MainActor
enum Announcer {
    private static let synthesizer = AVSpeechSynthesizer()

    /// `unprompted` output is suppressed during calls; a direct answer the user
    /// asked to hear is not.
    static func say(_ text: String, unprompted: Bool = true) {
        guard Settings.speakAnnouncements else { return }
        if unprompted, Presence.shouldStayQuiet { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.52
        synthesizer.speak(utterance)
    }

    static func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
