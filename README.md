# Relay Client

Capacitor iOS wrapper for [Eve Workspace](../eve). Loads Eve's web UI in a WKWebView from `https://eve.lan`.

## Architecture

```
WebView (loads https://eve.lan)
  |
  +-- Capacitor JS Bridge
  |
  +-- Native iOS (Swift)
        SSL Trust: Handles self-signed certificate for eve.lan
```

All TTS/STT processing is handled server-side by Eve.

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
