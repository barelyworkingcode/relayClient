import Foundation
import Capacitor

/// Handles SSL certificate trust for the eve.lan self-signed certificate.
@objc(SSLTrustPlugin)
public class SSLTrustPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SSLTrustPlugin"
    public let jsName = "SSLTrust"
    public let pluginMethods: [CAPPluginMethod] = []

    private let trustedHost = "eve.lan"

    override public func handleWKWebViewURLAuthenticationChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) -> Bool {
        let host = challenge.protectionSpace.host
        let authMethod = challenge.protectionSpace.authenticationMethod

        guard host == trustedHost,
              authMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            return false  // Not our host, let Capacitor handle it
        }

        let credential = URLCredential(trust: serverTrust)
        completionHandler(.useCredential, credential)
        print("[SSLTrust] Trusted certificate for \(host)")
        return true
    }
}
