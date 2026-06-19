import Foundation
import Capacitor
import os.log

private let sslLog = OSLog(subsystem: "com.barelyworkingcode.relayclient", category: "SSLTrust")

/// Single source of truth for trusting eve's self-signed certificate. Both the
/// WKWebView challenge (SSLTrustPlugin) and the native voice-pack URLSession
/// (EveTrustDelegate in EveVoice) route through here, so tightening this from
/// blanket server-trust to a pinned certificate fingerprint later is a one-place
/// change rather than two that can drift apart.
enum EveServerTrust {
    static let host = "eve.lan"

    /// A credential that accepts the challenge iff it is an eve.lan server-trust
    /// challenge; nil means "not ours — fall back to default handling."
    static func credential(for challenge: URLAuthenticationChallenge) -> URLCredential? {
        guard challenge.protectionSpace.host == host,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            return nil
        }
        return URLCredential(trust: serverTrust)
    }
}

/// Handles SSL certificate trust for the eve.lan self-signed certificate.
@objc(SSLTrustPlugin)
public class SSLTrustPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SSLTrustPlugin"
    public let jsName = "SSLTrust"
    public let pluginMethods: [CAPPluginMethod] = []

    override public func handleWKWebViewURLAuthenticationChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) -> Bool {
        guard let credential = EveServerTrust.credential(for: challenge) else {
            return false  // Not our host, let Capacitor handle it
        }
        completionHandler(.useCredential, credential)
        os_log("Trusted certificate for %{public}@", log: sslLog, type: .info, EveServerTrust.host)
        return true
    }
}
