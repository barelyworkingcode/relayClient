import Foundation
import Capacitor

@objc(EveVoicePlugin)
public class EveVoicePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "EveVoicePlugin"
    public let jsName = "EveVoice"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "loadModels", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startListening", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopListening", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "speak", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopSpeaking", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getStatus", returnType: CAPPluginReturnPromise),
    ]

    private let implementation = EveVoice()

    override public func load() {
        print("[EveVoice] Plugin loaded")
        implementation.onEvent = { [weak self] name, data in
            self?.notifyListeners(name, data: data)
        }
    }

    @objc func loadModels(_ call: CAPPluginCall) {
        Task {
            do {
                try await implementation.loadModels()
                call.resolve()
            } catch {
                call.reject("Failed to load models: \(error.localizedDescription)")
            }
        }
    }

    @objc func startListening(_ call: CAPPluginCall) {
        Task {
            do {
                try await implementation.startListening()
                call.resolve()
            } catch {
                call.reject("Failed to start listening: \(error.localizedDescription)")
            }
        }
    }

    @objc func stopListening(_ call: CAPPluginCall) {
        implementation.stopListening()
        call.resolve()
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
        let status = implementation.getStatus()
        call.resolve(status)
    }
}
