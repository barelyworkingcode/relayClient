# Relay Client

Capacitor iOS wrapper for [Eve Workspace](../eve). Loads Eve's web UI in a WKWebView from `https://eve.lan`.

## Architecture

```
WebView (loads https://eve.lan)
  |
  +-- Capacitor JS Bridge
  |
  +-- Native iOS (Swift)
        SSL Trust:    Handles self-signed certificate for eve.lan
        Safari Auth:  Passkey login via ASWebAuthenticationSession
        Eve Voice:    Native audio I/O for voice mode
        Eve Listener: Background audio session management
```

All TTS/STT processing is handled server-side by Eve.

## Authentication

Eve uses WebAuthn passkeys. iOS WKWebView blocks the WebAuthn API for local hostnames like `eve.lan` (it requires an Associated Domains entitlement verified via Apple's CDN, which can't reach local hosts). The app works around this with a Safari-based fallback:

1. Tap "Sign In" → WKWebView tries `navigator.credentials.get()` → iOS blocks it (`NotAllowedError`)
2. Eve's auth page detects the error + the `SafariAuth` plugin → calls `SafariAuth.login()`
3. A Safari sheet slides up showing `https://eve.lan/api/auth/safari-login` → Face ID passkey prompt appears
4. On success → Eve redirects to `relayclient://auth-callback?token=<session-token>` → Safari sheet dismisses
5. Token is stored in WKWebView `localStorage` → app is authenticated for 7 days (configurable via `EVE_SESSION_TTL_DAYS` on the Eve server)

When on the same LAN or VPN as Eve, the trusted-subnet bypass fires and no passkey is needed at all.

### Plugins

| Plugin | File | Purpose |
|--------|------|---------|
| `SSLTrust` | `Plugins/SSLTrust/SSLTrustPlugin.swift` | Trusts the self-signed `eve.lan` certificate in WKWebView |
| `SafariAuth` | `Plugins/SafariAuth/SafariAuthPlugin.swift` | Opens `ASWebAuthenticationSession` for passkey login when WKWebView blocks WebAuthn |
| `EveVoice` | `Plugins/EveVoice/EveVoicePlugin.swift` | Native audio I/O for voice mode |

## Setup

```bash
npm install
npx cap sync ios
```

Open in Xcode: `npx cap open ios`

Set your development team in Signing & Capabilities, then build and run.

## Build for Device

```bash
cd ios/App
xcodebuild -scheme App -destination 'platform=iOS,id=<DEVICE_ID>' build
```
