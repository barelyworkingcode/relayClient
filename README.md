# Relay Client

Capacitor iOS shell for [Eve Workspace](../eve). Wraps Eve's web UI in a WKWebView and provides native voice capabilities via the EveVoice plugin.

## Architecture

```
WebView (loads https://eve.lan)
  |
  +-- Capacitor JS Bridge
  |     EveVoice plugin (commands/events)
  |
  +-- Native iOS (Swift)
        TTS: Kokoro CoreML (neural) / AVSpeechSynthesizer (fallback)
        STT: SFSpeechRecognizer (on-device when available)
        Audio: AVAudioEngine
```

## Setup

```bash
npm install
npx cap sync ios
```

Open in Xcode: `npx cap open ios`

Set your development team in Signing & Capabilities, then build and run.

## IMPORTANT: kokoro-coreml Alignment Bug

The `Jud/kokoro-coreml` library has a bug in `VoiceStore.swift` that causes a crash:

```
Fatal error: load from misaligned raw pointer
```

**After any clean build or DerivedData wipe**, you must patch the checked-out source:

**File:** `ios/App/DerivedData/SourcePackages/checkouts/kokoro-coreml/Sources/KokoroCoreML/VoiceStore.swift`

**Replace all instances of:**
- `$0.load(fromByteOffset:` with `$0.loadUnaligned(fromByteOffset:`
- `buf.load(fromByteOffset:` with `buf.loadUnaligned(fromByteOffset:`

There are 4 occurrences (lines ~86, 87, 100, 103). A sed one-liner:

```bash
sed -i '' 's/\.load(fromByteOffset:/.loadUnaligned(fromByteOffset:/g' \
  ios/App/DerivedData/SourcePackages/checkouts/kokoro-coreml/Sources/KokoroCoreML/VoiceStore.swift
```

Then rebuild. This is needed until the upstream library is fixed.

## Build for Device

```bash
# Apply the kokoro-coreml patch first (see above), then:
cd ios/App
xcodebuild -scheme App -destination 'platform=iOS,id=<DEVICE_ID>' -derivedDataPath DerivedData clean build
```

## Model Download

Kokoro TTS models (~99MB) are downloaded automatically on first launch from GitHub releases. The models are cached in the app's Application Support directory and persist across app updates.
