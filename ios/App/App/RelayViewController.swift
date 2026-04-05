import UIKit
import Capacitor
import WebKit
import os.log

private let deepLinkLog = OSLog(subsystem: "com.barelyworkingcode.relayclient", category: "DeepLink")

class RelayViewController: CAPBridgeViewController {
    private var loadObserver: NSKeyValueObservation?

    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(SSLTrustPlugin())
        bridge?.registerPluginInstance(EveVoicePlugin())

        // Watch for initial page load to consume any pending deep link
        loadObserver = webView?.observe(\.isLoading, options: [.new]) { [weak self] _, change in
            if change.newValue == false {
                self?.consumePendingDeepLink()
            }
        }
    }

    private func consumePendingDeepLink() {
        loadObserver?.invalidate()
        loadObserver = nil

        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
              let path = appDelegate.pendingDeepLinkPath else { return }
        os_log("consumePendingDeepLink: %{public}@", log: deepLinkLog, type: .info, path)
        appDelegate.pendingDeepLinkPath = nil
        navigateToPath(path)
    }

    func navigateToPath(_ path: String) {
        os_log("navigateToPath: %{public}@, webView=%{public}@", log: deepLinkLog, type: .info, path, webView != nil ? "present" : "nil")

        let js = """
        (function() {
            // Debug toast
            var t = document.createElement('div');
            t.textContent = 'Action Button → #/\(path)';
            t.style.cssText = 'position:fixed;top:60px;left:50%;transform:translateX(-50%);background:#333;color:#0f0;padding:8px 16px;border-radius:8px;z-index:99999;font-size:14px;opacity:0.95;';
            document.body.appendChild(t);
            setTimeout(function() { t.remove(); }, 3000);

            // Navigate
            window.location.hash = '#/\(path)';
            return 'ok';
        })();
        """

        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js) { result, error in
                if let error = error {
                    os_log("JS eval error: %{public}@", log: deepLinkLog, type: .error, error.localizedDescription)
                } else {
                    os_log("JS eval success: %{public}@", log: deepLinkLog, type: .info, "\(result ?? "nil")")
                }
            }
        }
    }
}
