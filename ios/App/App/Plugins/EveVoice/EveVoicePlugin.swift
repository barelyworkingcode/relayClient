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

    // Track model readiness for toast management
    private var ttsReady = false
    private var sttReady = false

    override public func load() {
        print("[EveVoice] Plugin registered")

        implementation.onEvent = { [weak self] name, data in
            guard let self = self else { return }

            if name == "modelLoaded", let model = data["model"] as? String, model == "tts" {
                if let status = data["status"] as? String, status == "ready" {
                    self.ttsReady = true
                    self.updateLoadingToast()
                }
            }

            DispatchQueue.main.async {
                self.notifyListeners(name, data: data)
            }
        }

        listener.onEvent = { [weak self] name, data in
            guard let self = self else { return }

            if name == "modelLoaded", let model = data["model"] as? String, model == "asr" {
                if let status = data["status"] as? String, status == "ready" {
                    self.sttReady = true
                    self.updateLoadingToast()
                }
            }

            DispatchQueue.main.async {
                self.notifyListeners(name, data: data)
            }
        }
    }

    // MARK: - Loading Toast

    private func showToast(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            let escaped = message.replacingOccurrences(of: "'", with: "\\'")
            self?.bridge?.webView?.evaluateJavaScript("""
                (function() {
                    var t = document.getElementById('eve-loading-toast');
                    if (!t) {
                        t = document.createElement('div');
                        t.id = 'eve-loading-toast';
                        t.style.cssText = 'position:fixed;bottom:70px;left:50%;transform:translateX(-50%);background:rgba(30,30,30,0.92);color:#aaa;padding:8px 18px;border-radius:16px;font-size:13px;z-index:99999;pointer-events:none;font-family:-apple-system,system-ui,sans-serif;backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);transition:opacity 0.3s;white-space:nowrap;';
                        document.body.appendChild(t);
                    }
                    t.textContent = '\(escaped)';
                    t.style.opacity = '1';
                })();
            """, completionHandler: nil)
        }
    }

    private func hideToast() {
        DispatchQueue.main.async { [weak self] in
            self?.bridge?.webView?.evaluateJavaScript("""
                (function() {
                    var t = document.getElementById('eve-loading-toast');
                    if (t) { t.style.opacity = '0'; setTimeout(function(){ t.remove(); }, 300); }
                })();
            """, completionHandler: nil)
        }
    }

    private func updateLoadingToast() {
        if ttsReady && sttReady {
            hideToast()
        } else if ttsReady && !sttReady {
            showToast("Preparing speech recognition\u{2026}")
        } else if !ttsReady && sttReady {
            showToast("Preparing voice synthesis\u{2026}")
        } else {
            showToast("Downloading voice models\u{2026}")
        }
    }

    // MARK: - TTS

    @objc func loadModels(_ call: CAPPluginCall) {
        call.resolve()

        if !ttsReady || !sttReady {
            showToast("Downloading voice models\u{2026}")
        }

        Task {
            do {
                try await implementation.loadModels()
            } catch {
                print("[EveVoice] Background loadModels() failed: \(error.localizedDescription)")
            }
        }

        if !sttReady {
            Task {
                do {
                    try await listener.loadModels()
                } catch {
                    print("[EveVoice] Background STT loadModels() failed: \(error.localizedDescription)")
                }
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
        call.resolve()

        if !sttReady {
            showToast("Downloading speech recognition models\u{2026}")
        }

        Task {
            do {
                try await listener.loadModels()
            } catch {
                print("[EveVoice] Background loadSTTModels() failed: \(error.localizedDescription)")
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
