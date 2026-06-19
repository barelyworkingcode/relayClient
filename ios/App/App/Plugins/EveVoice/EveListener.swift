import AVFoundation
import FluidAudio
import Foundation
import os.log

private let sttLog = OSLog(subsystem: "com.barelyworkingcode.relayclient", category: "EveListener")

/// Native STT engine wrapping FluidAudio's StreamingAsrEngine.
/// Receives audio from JS (captured by JS VAD), transcribes it, and returns text.
/// No mic capture or VAD — those are handled by the JS layer (same as browser STT).
class EveListener: NSObject {
    var onEvent: ((String, [String: Any]) -> Void)?

    private var modelsLoaded = false
    private var loadingTask: Task<Void, Error>?
    private let loadLock = NSLock()

    private var asrEngine: (any StreamingAsrManager)?

    // MARK: - Model Management

    func loadModels() async throws {
        loadLock.lock()

        if modelsLoaded {
            loadLock.unlock()
            return
        }

        if let existing = loadingTask {
            loadLock.unlock()
            os_log("loadModels() — awaiting existing task", log: sttLog, type: .info)
            try await existing.value
            return
        }

        let task = Task<Void, Error> {
            let startTime = CFAbsoluteTimeGetCurrent()

            onEvent?("modelProgress", ["model": "asr", "progress": 0])
            os_log("Loading ASR model (Parakeet EOU 160ms)…", log: sttLog, type: .info)
            // 0.15.x: factory moved onto the variant; protocol renamed
            // StreamingAsrEngine → StreamingAsrManager (same method surface).
            let engine = StreamingModelVariant.parakeetEou160ms.createManager()
            try await engine.loadModels()
            self.asrEngine = engine
            onEvent?("modelProgress", ["model": "asr", "progress": 100])
            onEvent?("modelLoaded", ["model": "asr", "status": "ready"])

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            os_log("ASR model loaded in %.1fs", log: sttLog, type: .info, elapsed)

            self.modelsLoaded = true
        }

        loadingTask = task
        loadLock.unlock()

        do {
            try await task.value
        } catch {
            loadLock.lock()
            loadingTask = nil
            loadLock.unlock()
            os_log("Model loading FAILED: %{public}@", log: sttLog, type: .error, error.localizedDescription)
            onEvent?("modelLoaded", ["model": "asr", "status": "error", "message": error.localizedDescription])
            throw error
        }
    }

    // MARK: - Transcription

    /// Transcribe Float32 audio samples (16kHz mono) to text.
    /// Called by the plugin when JS sends captured audio from the VAD.
    func transcribe(samples: [Float]) async throws -> String {
        guard let engine = asrEngine else {
            throw EveListenerError.modelsNotLoaded
        }

        guard !samples.isEmpty else { return "" }

        let startTime = CFAbsoluteTimeGetCurrent()

        try await engine.reset()

        // Create AVAudioPCMBuffer from Float32 samples at 16kHz mono
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw EveListenerError.audioBufferCreationFailed
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                channelData[0].update(from: ptr.baseAddress!, count: samples.count)
            }
        }

        try await engine.appendAudio(buffer)
        try await engine.processBufferedAudio()
        let text = try await engine.finish()

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        os_log("Transcribed %ld samples in %.2fs → '%{private}@'", log: sttLog, type: .info, samples.count, elapsed, trimmed)

        return trimmed
    }

    // MARK: - Status

    func getStatus() -> [String: Any] {
        ["modelsLoaded": modelsLoaded]
    }
}

// MARK: - Errors

enum EveListenerError: LocalizedError {
    case modelsNotLoaded
    case audioBufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .modelsNotLoaded: return "STT models not loaded. Call loadSTTModels() first."
        case .audioBufferCreationFailed: return "Failed to create audio buffer from samples."
        }
    }
}
