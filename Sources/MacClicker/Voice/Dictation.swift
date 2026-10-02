import AVFAudio
import AVFoundation
import Foundation
import Speech

/// Push-to-talk dictation, on-device only.
///
/// `requiresOnDeviceRecognition` is set unconditionally and listening is refused when
/// the locale has no on-device model. Setting it to `supportsOnDeviceRecognition`
/// instead would be the obvious thing and is a quiet trapdoor: on a machine without
/// the model it evaluates to `false`, audio goes to Apple's servers, and the interface
/// still says the transcription is local. A promise about where speech goes has to
/// hold on every machine or it is not a promise.
///
/// The newer `SpeechAnalyzer`/`SpeechTranscriber` API on macOS 26 is better but needs
/// per-locale assets provisioned first; this path works everywhere the app runs.
@MainActor
final class Dictation: ObservableObject {

    @Published private(set) var transcript = ""
    @Published private(set) var isListening = false
    @Published private(set) var errorMessage: String?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    /// Whether this Mac can transcribe without the network. macOS downloads the model
    /// when Dictation is enabled for the language, so this is false until it is.
    var isOnDeviceAvailable: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    // MARK: - Permissions

    /// Two separate grants: the microphone, and speech recognition.
    static func requestPermissions() async -> Bool {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard mic else { return false }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Listening

    func start() {
        guard !isListening else { return }
        transcript = ""
        errorMessage = nil

        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available for \(Locale.current.identifier)."
            return
        }

        guard recognizer.supportsOnDeviceRecognition else {
            errorMessage = "No on-device speech model for \(Locale.current.identifier)."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Not negotiable: without the model we refuse above rather than fall back to
        // network transcription.
        request.requiresOnDeviceRecognition = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            errorMessage = "No usable audio input device."
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                // Ignore errors raised by our own cancellation on stop().
                if error != nil, self.isListening, self.transcript.isEmpty {
                    self.errorMessage = "Didn't catch that."
                }
            }
        }

        isListening = true
    }

    /// Stops listening and returns whatever was heard.
    @discardableResult
    func stop() -> String {
        guard isListening else { return transcript }
        isListening = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil

        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        guard isListening else { return }
        isListening = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        task?.cancel()
        request = nil
        task = nil
        transcript = ""
    }
}
