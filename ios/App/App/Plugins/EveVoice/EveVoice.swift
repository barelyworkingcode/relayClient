import Foundation
import AVFoundation
import Speech

/// Native voice implementation using Apple frameworks.
/// TTS: AVSpeechSynthesizer (built-in, no model download)
/// STT: SFSpeechRecognizer (on-device when available)
class EveVoice: NSObject {
    var onEvent: ((String, [String: Any]) -> Void)?

    private var isListening = false
    private var isSpeaking = false
    private var modelsLoaded = false
    private var shouldResumeListening = false

    // TTS
    private let synthesizer = AVSpeechSynthesizer()
    private var speakContinuation: CheckedContinuation<Void, Never>?
    private var speakContinuationResumed = false

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
        if modelsLoaded { return }

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

        // Pause STT if active so TTS can use the audio hardware
        let wasListening = isListening
        if wasListening {
            shouldResumeListening = false  // Prevent auto-restart from error handler
            isListening = false
            stopListeningInternal()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        if let selectedVoice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = selectedVoice
        }

        try configureAudioSession()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.speakContinuation = continuation
            self.speakContinuationResumed = false
            self.isSpeaking = true
            self.onEvent?("ttsStarted", [:])
            self.synthesizer.speak(utterance)
        }

        // Resume STT after speaking
        if wasListening {
            try? await Task.sleep(nanoseconds: 300_000_000)
            isListening = true
            shouldResumeListening = true
            try? await startListening()
        }
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        onEvent?("ttsFinished", [:])
        resumeSpeakContinuation()
    }

    private func resumeSpeakContinuation() {
        guard !speakContinuationResumed, let continuation = speakContinuation else { return }
        speakContinuationResumed = true
        speakContinuation = nil
        continuation.resume()
    }

    // MARK: - STT via SFSpeechRecognizer

    func startListening() async throws {
        if !modelsLoaded {
            try await loadModels()
        }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw EveVoiceError.speechRecognizerUnavailable
        }

        // Stop any existing session and ensure tap is fully removed
        stopListeningInternal()

        try configureAudioSession()

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else {
            throw EveVoiceError.speechRecognizerUnavailable
        }
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let inputNode = audioEngine.inputNode

        // Remove any lingering tap before installing a new one
        inputNode.removeTap(onBus: 0)

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
            let level = min(Double(rms * 5), 1.0)
            self?.onEvent?("audioLevel", ["level": level])
        }

        audioEngine.prepare()
        try audioEngine.start()

        isListening = true
        shouldResumeListening = true
        lastTranscription = ""
        onEvent?("speechStart", [:])

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                self.lastTranscription = text
                let isFinal = result.isFinal

                self.onEvent?("transcription", ["text": text, "isFinal": isFinal])
                self.resetSilenceTimer()

                if isFinal {
                    self.stopListeningInternal()
                    // Auto-restart for continuous conversation
                    if self.shouldResumeListening {
                        Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            if self.shouldResumeListening { try? await self.startListening() }
                        }
                    }
                }
            }

            if let error = error {
                let nsError = error as NSError
                let isCancellation = nsError.localizedDescription.lowercased().contains("cancel")
                let ignoredCodes = [216, 1110, 301, 209, 203]
                let isRoutine = (nsError.domain == "kAFAssistantErrorDomain" && ignoredCodes.contains(nsError.code)) || isCancellation

                if isRoutine {
                    // Auto-restart after transient errors (not cancellations)
                    if self.shouldResumeListening && !isCancellation {
                        Task {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            if self.shouldResumeListening { try? await self.startListening() }
                        }
                    }
                    return
                }
                self.onEvent?("error", ["message": error.localizedDescription, "code": "stt_error"])
            }
        }
    }

    func stopListening() {
        isListening = false
        shouldResumeListening = false
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
                self.onEvent?("transcription", ["text": self.lastTranscription, "isFinal": true])
                self.stopListeningInternal()
                if self.shouldResumeListening {
                    Task {
                        try? await self.startListening()
                    }
                }
            }
        }
    }

    // MARK: - Audio Session

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
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
        resumeSpeakContinuation()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        onEvent?("ttsFinished", [:])
        resumeSpeakContinuation()
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
