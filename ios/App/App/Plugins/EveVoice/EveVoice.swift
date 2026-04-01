import Foundation
import AVFoundation
import Speech

/// Native voice implementation using Apple frameworks.
/// TTS: AVSpeechSynthesizer (built-in, no model download)
/// STT: SFSpeechRecognizer (on-device recognition)
/// Future: swap in WhisperKit + Kokoro CoreML for higher quality.
class EveVoice: NSObject {
    var onEvent: ((String, [String: Any]) -> Void)?

    private var isListening = false
    private var isSpeaking = false
    private var modelsLoaded = false

    // TTS
    private let synthesizer = AVSpeechSynthesizer()

    // STT
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var lastTranscription = ""
    private var silenceTimer: Timer?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Model Management

    func loadModels() async throws {
        // Request speech recognition authorization
        let authStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard authStatus == .authorized else {
            throw EveVoiceError.speechRecognitionDenied
        }

        modelsLoaded = true
        onEvent?("modelLoaded", ["model": "stt", "status": "ready"])
        onEvent?("modelLoaded", ["model": "tts", "status": "ready"])
    }

    // MARK: - TTS via AVSpeechSynthesizer

    func speak(text: String, voice: String) async throws {
        if !modelsLoaded {
            try await loadModels()
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        // Try to pick a good voice
        if let selectedVoice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = selectedVoice
        }

        // Configure audio session for playback
        try configureAudioSession(forRecording: false)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.speakContinuation = continuation
            self.isSpeaking = true
            self.onEvent?("ttsStarted", [:])
            self.synthesizer.speak(utterance)
        }
    }

    private var speakContinuation: CheckedContinuation<Void, Never>?

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        onEvent?("ttsFinished", [:])
        speakContinuation?.resume()
        speakContinuation = nil
    }

    // MARK: - STT via SFSpeechRecognizer

    func startListening() async throws {
        if !modelsLoaded {
            try await loadModels()
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw EveVoiceError.speechRecognizerUnavailable
        }

        // Stop any existing session
        stopListeningInternal()

        try configureAudioSession(forRecording: true)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else {
            throw EveVoiceError.speechRecognizerUnavailable
        }
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)

            // Calculate audio level for orb visualization
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrt(sum / Float(frames))
            let level = min(Double(rms * 5), 1.0) // Amplify and clamp
            self?.onEvent?("audioLevel", ["level": level])
        }

        audioEngine.prepare()
        try audioEngine.start()

        isListening = true
        lastTranscription = ""
        onEvent?("speechStart", [:])

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                self.lastTranscription = text
                let isFinal = result.isFinal

                self.onEvent?("transcription", ["text": text, "isFinal": isFinal])

                // Reset silence timer on each partial result
                self.resetSilenceTimer()

                if isFinal {
                    self.stopListeningInternal()
                    // Auto-restart for continuous conversation
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s gap
                        if self.isListening {
                            try? await self.startListening()
                        }
                    }
                }
            }

            if let error = error {
                // Ignore cancellation errors (from stopListening)
                let nsError = error as NSError
                if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                    return // User cancelled
                }
                self.onEvent?("error", ["message": error.localizedDescription, "code": "stt_error"])
                self.stopListeningInternal()
            }
        }
    }

    func stopListening() {
        isListening = false
        stopListeningInternal()
        onEvent?("speechEnd", [:])
    }

    private func stopListeningInternal() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    private func resetSilenceTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.silenceTimer?.invalidate()
            self?.silenceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                guard let self = self, !self.lastTranscription.isEmpty else { return }
                // Silence detected — emit final transcription
                self.onEvent?("transcription", ["text": self.lastTranscription, "isFinal": true])
                self.stopListeningInternal()
                // Auto-restart for continuous listening
                if self.isListening {
                    Task {
                        try? await self.startListening()
                    }
                }
            }
        }
    }

    // MARK: - Audio Session

    private func configureAudioSession(forRecording: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if forRecording {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        } else {
            try session.setCategory(.playback, mode: .default)
        }
        try session.setActive(true)
    }

    // MARK: - Status

    func getStatus() -> [String: Any] {
        return [
            "modelsLoaded": modelsLoaded,
            "isListening": isListening,
            "isSpeaking": isSpeaking,
        ]
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension EveVoice: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        onEvent?("ttsFinished", [:])
        speakContinuation?.resume()
        speakContinuation = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        onEvent?("ttsFinished", [:])
        speakContinuation?.resume()
        speakContinuation = nil
    }
}

// MARK: - Errors

enum EveVoiceError: LocalizedError {
    case modelsNotLoaded
    case speechRecognitionDenied
    case speechRecognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .modelsNotLoaded:
            return "Models not loaded. Call loadModels() first."
        case .speechRecognitionDenied:
            return "Speech recognition permission denied."
        case .speechRecognizerUnavailable:
            return "Speech recognizer is not available."
        }
    }
}
