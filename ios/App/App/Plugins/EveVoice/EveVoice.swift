import Foundation
import AVFoundation
import FluidAudio

/// Native TTS engine wrapping FluidAudio's KokoroTtsManager.
/// Handles model downloading, synthesis, and audio playback on-device.
class EveVoice: NSObject {
    var onEvent: ((String, [String: Any]) -> Void)?

    private var modelsLoaded = false
    private var sessionConfigured = false
    private var loadingTask: Task<Void, Error>?
    private let loadLock = NSLock()

    private var ttsManager: KokoroTtsManager?
    private var audioPlayer: AVAudioPlayer?

    // MARK: - Model Management

    func loadModels() async throws {
        loadLock.lock()

        if modelsLoaded {
            loadLock.unlock()
            return
        }

        if let existing = loadingTask {
            loadLock.unlock()
            print("[EveVoice] loadModels() — awaiting existing task")
            try await existing.value
            return
        }

        let task = Task<Void, Error> {
            let startTime = CFAbsoluteTimeGetCurrent()
            onEvent?("modelProgress", ["model": "tts", "progress": 0])

            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let modelDir = appSupport.appendingPathComponent("fluidaudio/Models/kokoro")
            print("[EveVoice] Loading models (5s variant) from \(modelDir.path)")

            let manager = KokoroTtsManager(defaultVoice: "af_heart", directory: modelDir)
            let models = try await TtsModels.download(
                variants: [.fiveSecond],
                directory: modelDir
            )
            try await manager.initialize(models: models)

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            print("[EveVoice] Models loaded in \(String(format: "%.1f", elapsed))s")

            ttsManager = manager
            modelsLoaded = true

            onEvent?("modelProgress", ["model": "tts", "progress": 100])
            onEvent?("modelLoaded", ["model": "tts", "status": "ready"])
        }

        loadingTask = task
        loadLock.unlock()

        do {
            try await task.value
        } catch {
            loadLock.lock()
            loadingTask = nil
            loadLock.unlock()
            print("[EveVoice] Model loading FAILED: \(error.localizedDescription)")
            onEvent?("modelLoaded", ["model": "tts", "status": "error", "message": error.localizedDescription])
            throw error
        }
    }

    // MARK: - TTS

    func speak(text: String, voice: String) async throws {
        print("[EveVoice] speak() — \(text.count) chars, voice: \(voice)")

        if !modelsLoaded { try await loadModels() }

        guard let manager = ttsManager else {
            throw EveVoiceError.modelsNotLoaded
        }

        // Stop any in-progress playback before starting new synthesis
        if audioPlayer?.isPlaying == true {
            audioPlayer?.stop()
            audioPlayer = nil
        }

        if !sessionConfigured {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            sessionConfigured = true
            print("[EveVoice] Audio session configured")
        }

        onEvent?("ttsStarted", [:])
        let synthStart = CFAbsoluteTimeGetCurrent()

        do {
            let wavData = try await manager.synthesize(
                text: text,
                voice: voice,
                voiceSpeed: 1.0,
                variantPreference: .fiveSecond
            )

            let elapsed = CFAbsoluteTimeGetCurrent() - synthStart
            let duration = Double(wavData.count - 44) / (24000.0 * 2.0)
            print("[EveVoice] Synthesized in \(String(format: "%.2f", elapsed))s — \(String(format: "%.1f", duration))s audio")

            let player = try AVAudioPlayer(data: wavData)
            player.delegate = self
            audioPlayer = player
            player.play()
        } catch {
            onEvent?("ttsFinished", [:])
            print("[EveVoice] Synthesis FAILED: \(error.localizedDescription)")
            throw error
        }
    }

    func stopSpeaking() {
        audioPlayer?.stop()
        audioPlayer = nil
        onEvent?("ttsFinished", [:])
    }

    // MARK: - Voice Management

    /// American English voices only — other languages need G2P models
    /// that FluidAudio doesn't resolve with custom storage directories.
    func getVoices() -> [[String: String]] {
        let voices: [(id: String, name: String)] = [
            ("af_alloy", "Alloy"), ("af_aoede", "Aoede"), ("af_bella", "Bella"),
            ("af_heart", "Heart"), ("af_jessica", "Jessica"), ("af_kore", "Kore"),
            ("af_nicole", "Nicole"), ("af_nova", "Nova"), ("af_river", "River"),
            ("af_sarah", "Sarah"), ("af_sky", "Sky"),
            ("am_adam", "Adam"), ("am_echo", "Echo"), ("am_eric", "Eric"),
            ("am_fenrir", "Fenrir"), ("am_liam", "Liam"), ("am_michael", "Michael"),
            ("am_onyx", "Onyx"), ("am_puck", "Puck"), ("am_santa", "Santa"),
        ]

        return voices.map { v in
            [
                "id": v.id,
                "name": v.name,
                "lang": "American English",
                "gender": v.id.hasPrefix("af_") ? "F" : "M",
            ]
        }
    }

    func preloadVoice(_ voiceId: String) async throws {
        guard let manager = ttsManager else {
            throw EveVoiceError.modelsNotLoaded
        }
        print("[EveVoice] Preloading voice: \(voiceId)")
        try await manager.setDefaultVoice(voiceId)
        print("[EveVoice] Voice '\(voiceId)' ready")
    }

    // MARK: - Status

    func getStatus() -> [String: Any] {
        [
            "modelsLoaded": modelsLoaded,
            "isSpeaking": audioPlayer?.isPlaying ?? false,
            "kokoroReady": ttsManager != nil,
        ]
    }
}

// MARK: - AVAudioPlayerDelegate

extension EveVoice: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("[EveVoice] Playback finished (success: \(flag))")
        audioPlayer = nil
        onEvent?("ttsFinished", [:])
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("[EveVoice] Playback error: \(error?.localizedDescription ?? "unknown")")
        audioPlayer = nil
        onEvent?("ttsFinished", [:])
    }
}

enum EveVoiceError: LocalizedError {
    case modelsNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelsNotLoaded: return "Models not loaded. Call loadModels() first."
        }
    }
}
