import UIKit
import Capacitor
import os.log

private let deepLinkLog = OSLog(subsystem: "com.barelyworkingcode.relayclient", category: "DeepLink")

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    /// Pending path for cold launch only (consumed by KVO observer after WebView loads)
    var pendingDeepLinkPath: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if let url = launchOptions?[.url] as? URL,
           url.scheme == "relayclient" {
            os_log("Cold launch with URL: %{public}@", log: deepLinkLog, type: .info, url.absoluteString)
            pendingDeepLinkPath = url.host
        }
        return true
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
