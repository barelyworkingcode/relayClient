import Foundation
import Capacitor

@objc(EveVoicePlugin)
public class EveVoicePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "EveVoicePlugin"
    public let jsName = "EveVoice"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "loadModels", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "speak", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopSpeaking", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getVoices", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "preloadVoice", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "loadSTTModels", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "transcribe", returnType: CAPPluginReturnPromise),
    ]

    private let implementation = EveVoice()
    private let listener = EveListener()

    override public func load() {
        print("[EveVoice] Plugin registered")

        implementation.onEvent = { [weak self] name, data in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.notifyListeners(name, data: data)
            }
        }

        listener.onEvent = { [weak self] name, data in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.notifyListeners(name, data: data)
            }
        }
    }

    // MARK: - TTS

    @objc func loadModels(_ call: CAPPluginCall) {
        Task {
            do {
                try await implementation.loadModels()
                call.resolve()
            } catch {
                call.reject("TTS model loading failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func speak(_ call: CAPPluginCall) {
        guard let text = call.getString("text") else {
            call.reject("Missing 'text' parameter")
            return
        }
        let voice = call.getString("voice") ?? "af_heart"

        Task {
            do {
                let result = try await implementation.speak(text: text, voice: voice)
                call.resolve([
                    "audio": result.base64,
                    "duration": result.duration,
                ])
            } catch {
                call.reject("TTS failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func stopSpeaking(_ call: CAPPluginCall) {
        // No-op — JS handles playback now, so stopping is done JS-side
        call.resolve()
    }

    @objc func getStatus(_ call: CAPPluginCall) {
        var status = implementation.getStatus()
        let sttStatus = listener.getStatus()
        for (key, value) in sttStatus {
            status["stt_\(key)"] = value
        }
        call.resolve(status)
    }

    @objc func getVoices(_ call: CAPPluginCall) {
        call.resolve(["voices": implementation.getVoices()])
    }

    @objc func preloadVoice(_ call: CAPPluginCall) {
        guard let voice = call.getString("voice") else {
            call.reject("Missing 'voice' parameter")
            return
        }

        Task {
            do {
                try await implementation.preloadVoice(voice)
                call.resolve()
            } catch {
                call.reject("Preload failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - STT

    @objc func loadSTTModels(_ call: CAPPluginCall) {
        Task {
            do {
                try await listener.loadModels()
                call.resolve()
            } catch {
                call.reject("STT model loading failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func transcribe(_ call: CAPPluginCall) {
        guard let base64Audio = call.getString("audio") else {
            call.reject("Missing 'audio' parameter")
            return
        }

        guard let audioData = Data(base64Encoded: base64Audio) else {
            call.reject("Invalid base64 audio data")
            return
        }

        // Decode base64 → Float32 samples (16kHz mono from JS VAD)
        let samples = audioData.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }

        Task {
            do {
                let text = try await listener.transcribe(samples: samples)
                call.resolve(["text": text])
            } catch {
                call.reject("Transcription failed: \(error.localizedDescription)")
            }
        }
    }
}
