import UIKit
import Capacitor
import AVFoundation
import os.log

private let deepLinkLog = OSLog(subsystem: "com.barelyworkingcode.relayclient", category: "DeepLink")
private let audioLog = OSLog(subsystem: "com.barelyworkingcode.relayclient", category: "Audio")

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    /// Pending path for cold launch only (consumed by KVO observer after WebView loads)
    var pendingDeepLinkPath: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        configureAudioSession()

        if let url = launchOptions?[.url] as? URL,
           url.scheme == "relayclient" {
            os_log("Cold launch with URL: %{public}@", log: deepLinkLog, type: .info, url.absoluteString)
            pendingDeepLinkPath = url.host
        }
        return true
    }

    /// Configure the app-wide audio session so WKWebView TTS audio — now played
    /// in JS via Web Audio, not native AVAudioPlayer — is audible and plays even
    /// when the device is in silent mode. The eb1e1b4 "unify" refactor moved
    /// playback to JS and deleted the old per-AVAudioPlayer `.playback` setup,
    /// leaving Web Audio under the default `.soloAmbient` category (silenced by
    /// the mute switch). STT mic capture is handled by WebKit's getUserMedia,
    /// which reconfigures the session to a record-capable category on demand.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            os_log("Audio session configured: .playback/.spokenAudio", log: audioLog, type: .info)
        } catch {
            os_log("Audio session configuration failed: %{public}@", log: audioLog, type: .error, error.localizedDescription)
        }
    }

    func applicationWillResignActive(_ application: UIApplication) {}
    func applicationDidEnterBackground(_ application: UIApplication) {}
    func applicationWillEnterForeground(_ application: UIApplication) {}
    func applicationDidBecomeActive(_ application: UIApplication) {}
    func applicationWillTerminate(_ application: UIApplication) {}

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        if url.scheme == "relayclient" {
            let path = url.host ?? ""
            os_log("open URL: %{public}@, path: %{public}@", log: deepLinkLog, type: .info, url.absoluteString, path)

            guard let rootVC = window?.rootViewController as? RelayViewController else {
                // Cold launch — WebView not ready yet, defer to KVO observer
                os_log("WebView not ready — deferring to KVO observer", log: deepLinkLog, type: .info)
                pendingDeepLinkPath = path
                return true
            }

            // Warm resume — navigate after a short delay to let WebView wake from suspension
            os_log("Warm resume — scheduling navigation", log: deepLinkLog, type: .info)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                os_log("Executing delayed navigation to: %{public}@", log: deepLinkLog, type: .info, path)
                rootVC.navigateToPath(path)
            }
            return true
        }
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }
}
