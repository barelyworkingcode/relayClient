import Foundation
import FluidAudio

/// Native TTS engine wrapping FluidAudio's KokoroAneManager — the ANE-resident
/// 7-stage Kokoro CoreML chain (FluidAudio 0.15.x). Replaces the pre-0.14
/// single-graph KokoroTtsManager, whose CPU/BNNS execution path segfaults on
/// iOS 26. Handles model downloading and synthesis on-device.
/// Audio is returned as base64 WAV data — JS handles playback.
class EveVoice: NSObject {
    var onEvent: ((String, [String: Any]) -> Void)?

    /// The KokoroAne English model ships only `af_heart.bin` on HuggingFace.
    /// FluidAudio's voice-pack format is byte-identical to the upstream Kokoro
    /// `<voice>.safetensors` tensors, so eve hosts the rest of the English voice
    /// packs at `https://eve.lan/kokoro-voices/<id>.bin`; we fetch a requested
    /// voice into FluidAudio's cache on first use (see ensureVoicePack). Only
    /// English voices are listed — the model uses an English G2P frontend.
    static let defaultVoiceId = "af_heart"
    static let availableVoices: [(id: String, name: String, lang: String, gender: String)] = [
        ("af_heart", "Heart", "American English", "F"),
        ("af_bella", "Bella", "American English", "F"),
        ("af_nicole", "Nicole", "American English", "F"),
        ("af_nova", "Nova", "American English", "F"),
        ("af_sarah", "Sarah", "American English", "F"),
        ("af_sky", "Sky", "American English", "F"),
        ("am_adam", "Adam", "American English", "M"),
        ("am_echo", "Echo", "American English", "M"),
        ("am_eric", "Eric", "American English", "M"),
        ("am_michael", "Michael", "American English", "M"),
        ("bf_lily", "Lily", "British English", "F"),
        ("bm_daniel", "Daniel", "British English", "M"),
        ("bm_george", "George", "British English", "M"),
    ]
    static let availableVoiceIds: Set<String> = Set(availableVoices.map { $0.id })

    /// `<voice>.bin` is a flat fp32 [510, 256] style tensor = 522,240 bytes.
    private static let voicePackByteCount = 510 * 256 * MemoryLayout<Float>.size
    private static let voiceBaseURL = "https://eve.lan/kokoro-voices"

    /// Where FluidAudio's KokoroAne loader looks for `<voice>.bin` (pinned to
    /// FluidAudio 0.15.1's layout). Pre-placing a file here makes its loader use
    /// it instead of trying (and failing) to download it from HuggingFace.
    private static let voiceCacheDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("fluidaudio/Models/kokoro-82m-coreml/ANE", isDirectory: true)
    }()

    /// URLSession that trusts the eve.lan self-signed cert for voice-pack fetches,
    /// mirroring SSLTrustPlugin's WKWebView handling. Scoped strictly to eve.lan.
    private static let eveSession: URLSession = {
        URLSession(configuration: .ephemeral, delegate: EveTrustDelegate(), delegateQueue: nil)
    }()

    private var modelsLoaded = false
    private var loadingTask: Task<Void, Error>?
    private let loadLock = NSLock()

    private var ttsManager: KokoroAneManager?

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

            print("[EveVoice] Loading Kokoro ANE models (downloads from HF on first use)")

            // KokoroAneManager.initialize() downloads (if missing) and loads the
            // 7-stage ANE model chain + vocab + default voice pack in one call —
            // no separate TtsModels.download step.
            //
            // computeUnits: .default (FluidAudio's empirical per-stage optima —
            // ANE-resident encoder/vocoder, scheduler-picked prosody/noise/tail).
            // This is the only config that produces CORRECT audio: the model uses
            // data-dependent (dynamic) shapes that only compute right on the ANE.
            // Forcing stages onto GPU/CPU (.cpuAndGpu) avoids the crash but
            // disables dynamic shapes → garbled output, so it's not viable.
            // The ANE path intermittently segfaults in libBNNS on iOS 26.5.1
            // (an upstream FluidAudio/Apple bug); eve's VoiceCrashGuard recovers
            // to the server backend if that happens.
            let manager = KokoroAneManager(
                variant: .english,
                defaultVoice: "af_heart"
            )
            try await manager.initialize()

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

    /// Synthesize text to WAV audio and return the data + duration.
    /// JS handles playback via AudioContext — no native AVAudioPlayer needed.
    func speak(text: String, voice: String) async throws -> (base64: String, duration: Double) {
        print("[EveVoice] speak() — \(text.count) chars, voice: \(voice)")

        if !modelsLoaded { try await loadModels() }

        guard let manager = ttsManager else {
            throw EveVoiceError.modelsNotLoaded
        }

        // Resolve the voice. af_heart ships with the model; other English voices
        // are fetched from eve into the model cache on first use. Anything we
        // can't make available (unknown voice, or a failed fetch) falls back to
        // af_heart so synthesis still produces audio instead of a 404.
        var effectiveVoice = EveVoice.availableVoiceIds.contains(voice) ? voice : EveVoice.defaultVoiceId
        if effectiveVoice != EveVoice.defaultVoiceId {
            await ensureVoicePack(effectiveVoice)
            if !EveVoice.voicePackInstalled(effectiveVoice) {
                print("[EveVoice] Voice '\(effectiveVoice)' unavailable — falling back to \(EveVoice.defaultVoiceId)")
                effectiveVoice = EveVoice.defaultVoiceId
            }
        }
        if effectiveVoice != voice {
            print("[EveVoice] Requested voice '\(voice)' → using '\(effectiveVoice)'")
        }

        let synthStart = CFAbsoluteTimeGetCurrent()

        let wavData = try await manager.synthesize(
            text: text,
            voice: effectiveVoice,
            speed: 1.0
        )

        // WAV: 44-byte header, 24kHz, 16-bit mono
        let duration = Double(wavData.count - 44) / (24000.0 * 2.0)
        let synthElapsed = CFAbsoluteTimeGetCurrent() - synthStart
        let base64 = wavData.base64EncodedString()
        print("[EveVoice] Synthesized \(String(format: "%.2f", duration))s audio in \(String(format: "%.2f", synthElapsed))s — sending \(base64.count) base64 bytes to JS")
        return (base64: base64, duration: duration)
    }

    // MARK: - Voice Management

    /// English Kokoro voices supported on-device. af_heart ships with the model;
    /// the rest are fetched from eve on first use (see ensureVoicePack).
    func getVoices() -> [[String: String]] {
        return EveVoice.availableVoices.map { v in
            ["id": v.id, "name": v.name, "lang": v.lang, "gender": v.gender]
        }
    }

    func preloadVoice(_ voiceId: String) async throws {
        guard let manager = ttsManager else {
            throw EveVoiceError.modelsNotLoaded
        }
        var effectiveVoice = EveVoice.availableVoiceIds.contains(voiceId) ? voiceId : EveVoice.defaultVoiceId
        if effectiveVoice != EveVoice.defaultVoiceId {
            await ensureVoicePack(effectiveVoice)
            if !EveVoice.voicePackInstalled(effectiveVoice) { effectiveVoice = EveVoice.defaultVoiceId }
        }
        print("[EveVoice] Setting default voice: \(effectiveVoice)")
        await manager.setDefaultVoice(effectiveVoice)
        print("[EveVoice] Voice '\(effectiveVoice)' set (pack loads on next synthesis)")
    }

    // MARK: - Voice pack fetching (eve-hosted)

    /// True if `<voice>.bin` is already in FluidAudio's cache (af_heart ships
    /// with the model, so it's always considered installed).
    private static func voicePackInstalled(_ voice: String) -> Bool {
        if voice == defaultVoiceId { return true }
        return FileManager.default.fileExists(atPath: voiceCacheDir.appendingPathComponent("\(voice).bin").path)
    }

    /// Fetch a Kokoro voice pack from eve into FluidAudio's cache dir if it's not
    /// already there. FluidAudio only hosts af_heart on HuggingFace; eve serves
    /// the rest in the model's native format. No-op (logs) on failure — the caller
    /// falls back to af_heart.
    private func ensureVoicePack(_ voice: String) async {
        if EveVoice.voicePackInstalled(voice) { return }
        guard let url = URL(string: "\(EveVoice.voiceBaseURL)/\(voice).bin") else { return }
        do {
            let (data, response) = try await EveVoice.eveSession.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200, data.count == EveVoice.voicePackByteCount else {
                print("[EveVoice] Voice pack fetch '\(voice)' failed (status \(status), \(data.count) bytes)")
                return
            }
            try FileManager.default.createDirectory(at: EveVoice.voiceCacheDir, withIntermediateDirectories: true)
            try data.write(to: EveVoice.voiceCacheDir.appendingPathComponent("\(voice).bin"), options: .atomic)
            print("[EveVoice] Installed voice pack '\(voice)' (\(data.count) bytes) from eve")
        } catch {
            print("[EveVoice] Voice pack fetch '\(voice)' errored: \(error.localizedDescription)")
        }
    }

    // MARK: - Status

    func getStatus() -> [String: Any] {
        [
            "modelsLoaded": modelsLoaded,
            "kokoroReady": ttsManager != nil,
        ]
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

/// Trusts the eve.lan self-signed certificate for native voice-pack fetches,
/// mirroring SSLTrustPlugin's WKWebView handling. Scoped strictly to eve.lan —
/// every other host uses default TLS validation.
private final class EveTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.host == "eve.lan",
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
