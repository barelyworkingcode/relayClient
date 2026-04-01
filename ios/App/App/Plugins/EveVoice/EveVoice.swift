import Foundation
import AVFoundation
import Speech
import KokoroCoreML

/// Native voice implementation.
/// TTS: Kokoro CoreML (high-quality neural TTS), AVSpeechSynthesizer fallback
/// STT: SFSpeechRecognizer (on-device when available)
class EveVoice: NSObject {
    var onEvent: ((String, [String: Any]) -> Void)?

    private var isListening = false
    private var isSpeaking = false
    private var modelsLoaded = false
    private var shouldResumeListening = false

    // TTS - Kokoro
    private var kokoroEngine: KokoroEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playbackEngine: AVAudioEngine?

    // TTS - fallback
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

        // Request speech recognition auth (deferred — don't block TTS model loading)
        Task {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { s in
                    continuation.resume(returning: s)
                }
            }
        }

        // Download Kokoro models on first use (~99MB), then init engine
        let modelDir = KokoroEngine.defaultModelDirectory
        do {
            if !KokoroEngine.isDownloaded(at: modelDir) {
                onEvent?("modelProgress", ["model": "tts", "progress": 0])
                try await KokoroModelFetcher.download(to: modelDir) { progress in
                    self.onEvent?("modelProgress", ["model": "tts", "progress": progress])
                }
            }
            kokoroEngine = try KokoroEngine(modelDirectory: modelDir)
            onEvent?("modelLoaded", ["model": "tts", "status": "ready"])
        } catch {
            onEvent?("modelLoaded", ["model": "tts", "status": "fallback"])
        }

        modelsLoaded = true
        onEvent?("modelLoaded", ["model": "stt", "status": "ready"])
    }

    // MARK: - TTS

    func speak(text: String, voice: String) async throws {
        if !modelsLoaded {
            try await loadModels()
        }

        // Pause STT if active
        let wasListening = isListening
        if wasListening {
            shouldResumeListening = false
            isListening = false
            stopListeningInternal()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        try configureAudioSession()

        if let engine = kokoroEngine {
            try await speakWithKokoro(engine, text: text, voice: voice)
        } else {
            try await speakWithAVSpeech(text: text)
        }

        // Resume STT after speaking
        if wasListening {
            try? await Task.sleep(nanoseconds: 300_000_000)
            isListening = true
            shouldResumeListening = true
            try? await startListening()
        }
    }

    private func speakWithKokoro(_ engine: KokoroEngine, text: String, voice: String) async throws {
        isSpeaking = true
        onEvent?("ttsStarted", [:])

        do {
            let format = KokoroEngine.audioFormat
            let pEngine = AVAudioEngine()
            let pNode = AVAudioPlayerNode()
            pEngine.attach(pNode)
            pEngine.connect(pNode, to: pEngine.mainMixerNode, format: format)
            try pEngine.start()
            pNode.play()
            playbackEngine = pEngine
            playerNode = pNode

            var hasAudio = false
            for await event in try engine.speak(text, voice: voice) {
                switch event {
                case .audio(let buffer):
                    hasAudio = true
                    await pNode.scheduleBuffer(buffer)
                case .chunkFailed:
                    break
                }
            }

            if !hasAudio {
                throw EveVoiceError.ttsNoAudio
            }

            pNode.stop()
            pEngine.stop()
            playbackEngine = nil
            playerNode = nil
        } catch {
            playbackEngine?.stop()
            playbackEngine = nil
            playerNode = nil
            try await speakWithAVSpeech(text: text)
            return
        }

        isSpeaking = false
        onEvent?("ttsFinished", [:])
    }

    private func speakWithAVSpeech(text: String) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.speakContinuation = continuation
            self.speakContinuationResumed = false
            self.isSpeaking = true
            self.onEvent?("ttsStarted", [:])
            self.synthesizer.speak(utterance)
        }
    }

    func stopSpeaking() {
        playerNode?.stop()
        playbackEngine?.stop()
        playbackEngine = nil
        playerNode = nil
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
        inputNode.removeTap(onBus: 0)
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames { sum += channelData[i] * channelData[i] }
            let rms = sqrt(sum / Float(frames))
            self?.onEvent?("audioLevel", ["level": min(Double(rms * 5), 1.0)])
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
                self.onEvent?("transcription", ["text": text, "isFinal": result.isFinal])
                self.resetSilenceTimer()

                if result.isFinal {
                    self.stopListeningInternal()
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
                    Task { try? await self.startListening() }
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
            "kokoroReady": kokoroEngine != nil,
        ]
    }
}

// MARK: - AVSpeechSynthesizerDelegate (fallback TTS)

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

enum EveVoiceError: LocalizedError {
    case modelsNotLoaded
    case speechRecognitionDenied
    case speechRecognizerUnavailable
    case ttsNoAudio

    var errorDescription: String? {
        switch self {
        case .modelsNotLoaded: return "Models not loaded. Call loadModels() first."
        case .speechRecognitionDenied: return "Speech recognition permission denied."
        case .speechRecognizerUnavailable: return "Speech recognizer is not available."
        case .ttsNoAudio: return "TTS produced no audio."
        }
    }
}
