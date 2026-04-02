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
        CAPPluginMethod(name: "startListening", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopListening", returnType: CAPPluginReturnPromise),
    ]

    private let implementation = EveVoice()

    override public func load() {
        print("[EveVoice] Plugin registered")

        implementation.onEvent = { [weak self] name, data in
            DispatchQueue.main.async {
                self?.notifyListeners(name, data: data)
            }
        }
    }

    @objc func loadModels(_ call: CAPPluginCall) {
        // Resolve immediately — initialization continues in background.
        // speak() awaits if models aren't ready yet.
        call.resolve()

        Task {
            do {
                try await implementation.loadModels()
            } catch {
                print("[EveVoice] Background loadModels() failed: \(error.localizedDescription)")
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
                try await implementation.speak(text: text, voice: voice)
                call.resolve()
            } catch {
                call.reject("TTS failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func stopSpeaking(_ call: CAPPluginCall) {
        implementation.stopSpeaking()
        call.resolve()
    }

    @objc func getStatus(_ call: CAPPluginCall) {
        call.resolve(implementation.getStatus())
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

    // MARK: - STT stubs (not yet implemented)

    @objc func startListening(_ call: CAPPluginCall) {
        call.reject("STT not yet implemented")
    }

    @objc func stopListening(_ call: CAPPluginCall) {
        call.resolve()
    }
}
