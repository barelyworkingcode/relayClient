import Foundation
import Capacitor
import AuthenticationServices

/// Opens a passkey login flow in Safari via ASWebAuthenticationSession.
///
/// WKWebView blocks WebAuthn (navigator.credentials.get) unless the app has
/// a verified Associated Domains entitlement — which requires Apple's CDN to
/// reach the domain (impossible for local/dynamic hostnames like eve.lan).
/// Safari has full passkey support without that restriction, so we delegate
/// the ceremony to Safari and capture the session token via a callback URL.
@objc(SafariAuthPlugin)
public class SafariAuthPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SafariAuthPlugin"
    public let jsName = "SafariAuth"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "login", returnType: CAPPluginReturnPromise)
    ]

    private let callbackScheme = "relayclient"

    @objc func login(_ call: CAPPluginCall) {
        guard let bridge = self.bridge else {
            call.reject("No bridge available")
            return
        }

        let loginURL = bridge.config.serverURL.appendingPathComponent("/api/auth/safari-login")

        DispatchQueue.main.async {
            let session = ASWebAuthenticationSession(
                url: loginURL,
                callbackURLScheme: self.callbackScheme
            ) { callbackURL, error in
                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                       nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        call.reject("User cancelled login")
                    } else {
                        call.reject("Safari auth failed: \(error.localizedDescription)")
                    }
                    return
                }

                guard let url = callbackURL,
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let token = components.queryItems?.first(where: { $0.name == "token" })?.value else {
                    call.reject("No token in callback URL")
                    return
                }

                call.resolve(["token": token])
            }

            // Use the RelayViewController as the presentation context so the
            // Safari sheet appears over the app. RelayViewController conforms
            // to ASWebAuthenticationPresentationContextProviding.
            if let vc = bridge.viewController as? ASWebAuthenticationPresentationContextProviding {
                session.presentationContextProvider = vc
            }

            session.prefersEphemeralWebBrowserSession = false // Share Safari's passkey store
            session.start()
        }
    }
}
