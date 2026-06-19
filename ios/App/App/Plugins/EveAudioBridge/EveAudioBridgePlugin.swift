import Foundation
import Capacitor
import UIKit
import os.log

private let pluginLog = OSLog(subsystem: "com.barelyworkingcode.relayclient", category: "AudioBridge")

/// Capacitor surface for the native voice audio loop (see `EveAudioEngine`).
/// JS drives it with `window.Capacitor.nativePromise('EveAudioBridge', method, args)`
/// and subscribes to events via `Capacitor.Plugins.EveAudioBridge.addListener(...)`.
@objc(EveAudioBridgePlugin)
public class EveAudioBridgePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "EveAudioBridgePlugin"
    public let jsName = "EveAudioBridge"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "startSession", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopSession", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setMode", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startCapture", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopCapture", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "enqueueTTS", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "endTTSTurn", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopPlayback", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "playEarcon", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startThinkingCue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopThinkingCue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "haptic", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setTuning", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startKeepaliveProbe", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopKeepaliveProbe", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "dumpLogs", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setDiagLogging", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getDiagLogging", returnType: CAPPluginReturnPromise),
    ]

    private let engine = EveAudioEngine()

    override public func load() {
        os_log("EveAudioBridge plugin registered", log: pluginLog, type: .info)
        engine.onEvent = { [weak self] name, data in
            DispatchQueue.main.async { self?.notifyListeners(name, data: data) }
        }
        engine.observeAudioSession()
    }

    private func parseMode(_ call: CAPPluginCall) -> EveAudioEngine.Mode {
        EveAudioEngine.Mode(rawValue: call.getString("mode") ?? "handsfree") ?? .handsfree
    }

    @objc func startSession(_ call: CAPPluginCall) {
        engine.startSession(mode: parseMode(call))
        call.resolve()
    }

    @objc func stopSession(_ call: CAPPluginCall) {
        engine.stopSession()
        call.resolve()
    }

    @objc func setMode(_ call: CAPPluginCall) {
        engine.setMode(parseMode(call))
        call.resolve()
    }

    @objc func startCapture(_ call: CAPPluginCall) {
        engine.startCapture()
        call.resolve()
    }

    @objc func stopCapture(_ call: CAPPluginCall) {
        engine.stopCapture()
        call.resolve()
    }

    @objc func enqueueTTS(_ call: CAPPluginCall) {
        guard let audio = call.getString("audio") else {
            call.reject("Missing 'audio' (base64 WAV)")
            return
        }
        engine.enqueueTTS(base64: audio)
        call.resolve()
    }

    @objc func endTTSTurn(_ call: CAPPluginCall) {
        engine.endTTSTurn()
        call.resolve()
    }

    @objc func stopPlayback(_ call: CAPPluginCall) {
        engine.stopPlayback()
        call.resolve()
    }

    @objc func playEarcon(_ call: CAPPluginCall) {
        engine.playEarcon(call.getString("name") ?? "listening")
        call.resolve()
    }

    @objc func startThinkingCue(_ call: CAPPluginCall) {
        engine.startThinkingCue()
        call.resolve()
    }

    @objc func stopThinkingCue(_ call: CAPPluginCall) {
        engine.stopThinkingCue()
        call.resolve()
    }

    /// Foreground-only — iOS suppresses haptics when the app is backgrounded /
    /// the device is locked, so eyes-free feedback while walking relies on
    /// earcons. This is a confirmation cue for on-screen interactions.
    @objc func haptic(_ call: CAPPluginCall) {
        let style = call.getString("style") ?? "light"
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState == .active else { call.resolve(); return }
            let mapped: UIImpactFeedbackGenerator.FeedbackStyle
            switch style {
            case "medium": mapped = .medium
            case "heavy": mapped = .heavy
            case "rigid": mapped = .rigid
            case "soft": mapped = .soft
            default: mapped = .light
            }
            UIImpactFeedbackGenerator(style: mapped).impactOccurred()
            call.resolve()
        }
    }

    /// Live VAD/barge-in tuning from JS — eve's frontend ships without an app
    /// rebuild, so thresholds can be dialed in on-device. Omitted keys keep
    /// their current values. Resolves with the resulting status for inspection.
    @objc func setTuning(_ call: CAPPluginCall) {
        engine.setTuning(
            bargeInEnabled: call.getBool("bargeInEnabled"),
            bargeInRmsThreshold: call.getDouble("bargeInRmsThreshold"),
            bargeInWindowMs: call.getDouble("bargeInWindowMs"),
            bargeInMinVoicedMs: call.getDouble("bargeInMinVoicedMs"))
        call.resolve(engine.getStatus())
    }

    @objc func getStatus(_ call: CAPPluginCall) {
        call.resolve(engine.getStatus())
    }

    @objc func startKeepaliveProbe(_ call: CAPPluginCall) {
        engine.startKeepaliveProbe()
        call.resolve()
    }

    @objc func stopKeepaliveProbe(_ call: CAPPluginCall) {
        engine.stopKeepaliveProbe()
        call.resolve()
    }

    /// Drain the in-app diagnostic ring buffer (see DiagLog) so JS can flush any
    /// lines that were emitted before it subscribed to onDiagLog — e.g. the
    /// app-launch → first-session cold-start trace — and forward them to eve.
    @objc func dumpLogs(_ call: CAPPluginCall) {
        call.resolve(["lines": DiagLog.shared.dump()])
    }

    /// Toggle device-log streaming to eve (persisted natively; default off).
    @objc func setDiagLogging(_ call: CAPPluginCall) {
        engine.setDiagLogging(call.getBool("enabled") ?? false)
        call.resolve(["enabled": engine.diagLoggingOn])
    }

    @objc func getDiagLogging(_ call: CAPPluginCall) {
        call.resolve(["enabled": engine.diagLoggingOn])
    }
}
