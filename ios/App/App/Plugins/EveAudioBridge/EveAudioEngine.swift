import AVFoundation
import Foundation
import UIKit
import os.log

private let audioLog = OSLog(subsystem: "com.barelyworkingcode.relayclient", category: "AudioBridge")

/// Native audio I/O loop for voice chat. Owns the mic (capture + endpointing)
/// and the speaker (TTS playback) so a conversation keeps running with the
/// screen off: an actively-running `AVAudioEngine` under `UIBackgroundModes:
/// audio` holds the background assertion, which keeps the whole app — the
/// WKWebView's JS event loop and its WebSocket — alive while the device is
/// locked.
///
/// It runs NO ML model. Transcription and synthesis stay on the eve server.
/// Native only does hardware audio + an energy-based VAD endpointer: it emits
/// captured utterances to JS as 16 kHz mono WAV (the exact shape the server's
/// `transcribe_audio` expects) and plays back the WAV chunks the server streams.
///
/// Duplex with a strict gate — Apple's voice-processing unit (echo
/// cancellation) runs on the engine I/O so the mic doesn't hear Eve's own TTS,
/// and while Eve is speaking the mic feeds a deliberately *less* sensitive
/// barge-in detector: a firm, sustained "stop" interrupts playback; a cough or
/// "hrmm" does not. When idle-listening the normal (more sensitive) endpointer
/// applies. If voice processing can't be enabled, barge-in is disabled and the
/// engine falls back to the original half-duplex behavior.
final class EveAudioEngine: NSObject {
    enum Mode: String { case handsfree, ptt }

    /// Raw event sink. The plugin wraps this to marshal onto the main thread
    /// before calling `notifyListeners`, so this may be invoked from any thread.
    var onEvent: ((String, [String: Any]) -> Void)?

    // MARK: Audio graph
    // `var` (not `let`): after a media-services reset the engine and every node
    // are dead objects and must be recreated wholesale (see rebuildEngine()).
    private var engine = AVAudioEngine()
    private var ttsPlayer = AVAudioPlayerNode()
    private var earconPlayer = AVAudioPlayerNode()
    private var keepalivePlayer = AVAudioPlayerNode()

    /// True when Apple's voice-processing unit (echo cancellation) is active on
    /// the engine I/O. Barge-in requires it: without AEC the mic hears Eve's own
    /// TTS from the speaker and would trip the detector on every reply.
    private var aecActive = false

    /// 16 kHz mono float — what the VAD runs on and what we ship to STT.
    private let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    /// 24 kHz mono float — Kokoro's native rate; the mixer resamples to HW out.
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    private var inputConverter: AVAudioConverter?

    // MARK: State
    private var sessionActive = false
    private var graphConnected = false
    private var mode: Mode = .handsfree
    private var pttCapturing = false
    private var interrupted = false

    /// Set while TTS audio is queued/playing. The VAD is suppressed so Eve's
    /// own voice can't trigger an utterance (half-duplex).
    private var isSpeaking = false
    private var pendingTTSBuffers = 0
    /// A "turn" spans all the sentence chunks of one assistant response. The
    /// queue can briefly drain *between* chunks (network gaps), so a drain only
    /// ends the turn once the server has signalled it's done (`endTTSTurn`).
    private var ttsTurnActive = false
    private var ttsTurnComplete = false
    /// Bumped on barge-in / stop so completion handlers from abandoned buffers
    /// don't decrement the new generation's count.
    private var playbackGeneration = 0
    private let playbackLock = NSLock()

    /// Wall-clock deadline until which the mic is ignored because an earcon is
    /// sounding. We can't use `earconPlayer.isPlaying` for this: an
    /// AVAudioPlayerNode reports `isPlaying` from `play()` until `stop()`,
    /// independent of whether a buffer is actually audible — and the node is
    /// started once at session start, so it would suppress the mic forever.
    private var earconUntil: CFAbsoluteTime = 0

    /// Repeating faint tick while it's the AI's turn but it hasn't spoken yet
    /// (thinking / tool-calling), so the user gets an eyes-free "something is
    /// happening" signal. Started/stopped from JS around the request.
    private var thinkingTimer: DispatchSourceTimer?

    /// Serializes utterance finalization (WAV encode + base64) off the realtime
    /// audio thread.
    private let finalizeQueue = DispatchQueue(label: "com.barelyworkingcode.relayclient.audio.finalize")

    // MARK: VAD tunables (energy endpointer; ~20 ms frames at 16 kHz)
    private let frameSamples = 320
    private let rmsThreshold: Float = 0.012
    private let startFrames = 3        // ~60 ms over threshold confirms speech
    private let endSilenceFrames = 40  // ~800 ms under threshold ends the turn
    private let minUtteranceFrames = 12 // ~240 ms floor for PTT (deliberate hold)
    // Hands-free needs a higher floor: the VAD will occasionally endpoint on a
    // cough / footstep / half-second of noise, and Whisper hallucinates a junk
    // word from it. Drop anything under ~0.5 s of actual speech before it's ever
    // sent to STT.
    private let minHandsfreeVoicedFrames = 25 // ~500 ms of voiced speech
    private let maxUtteranceFrames = 1500 // ~30 s hard cap
    private let preRollFrames = 15     // ~300 ms kept so we don't clip onsets
    private let levelEmitEveryFrames = 5 // ~100 ms cadence for the orb

    // MARK: Barge-in tunables (mic gate while Eve is speaking)
    // Deliberately much stricter than the listening VAD. A false barge-in (Eve
    // cuts herself off over a cough, a "hrmm", or residual echo) is worse than a
    // missed one — the user can always repeat a firm "stop", but a phantom
    // interruption kills the reply. Defaults require roughly a firmly-spoken
    // word sustained near the mic. `var` so JS can tune them live via setTuning
    // (eve's frontend ships without an app rebuild).
    private var bargeInEnabled = true
    private var bargeInRmsThreshold: Float = 0.035 // ~3x the listening threshold
    private var bargeInWindowFrames = 40           // 800 ms evidence window
    private var bargeInMinVoicedFrames = 22        // ≥ ~440 ms voiced within it

    // MARK: VAD running state (touched only on the audio thread)
    private var frameAccumulator: [Float] = []
    private var preRoll: [[Float]] = []
    private var utterance: [Float] = []
    private var inSpeech = false
    private var speechRun = 0
    private var silenceRun = 0
    private var levelFrameCounter = 0
    private var loggedFirstBuffer = false

    // MARK: Barge-in running state (touched only on the audio thread)
    /// Ring of the last `bargeInWindowFrames` frames heard during TTS, so a
    /// triggered barge-in keeps the words that triggered it ("stop, actually…").
    private var bargeInRing: [[Float]] = []
    private var bargeInVoicedFlags: [Bool] = []
    private var bargeInVoicedCount = 0
    /// Set from trigger until the barged-in utterance finalizes. Bridges the gap
    /// while `isSpeaking` flips off asynchronously, suppresses the listening
    /// earcon (the user is mid-sentence), and rejects stale TTS chunks that were
    /// already in flight when the user interrupted.
    private var bargeInCapturing = false

    // MARK: Background survival
    /// Restarts a dead engine while a session is supposed to be live. With the
    /// screen off the background-audio assertion *is* the process's lifeline —
    /// any silent engine death (failed resume, config-change error) would
    /// otherwise suspend the app within seconds.
    private var watchdogTimer: DispatchSourceTimer?
    /// UIKit background task held while audio is down (interruption / recovery
    /// in progress). Buys ~30 s of runtime with the screen off so the engine can
    /// be restarted after a Siri prompt, alarm, or transient session grab —
    /// without it the process suspends before the interruption even ends.
    private var recoveryTask: UIBackgroundTaskIdentifier = .invalid

    /// Wall-clock of the last watchdog tick. A gap to the current tick far larger
    /// than the 3 s interval means the process was suspended in between — the
    /// signal we're hunting (Issue 2).
    private var lastWatchdogTick: CFAbsoluteTime = 0
    /// True once the mic tap is installed. The tap is best-effort and decoupled
    /// from the background-critical playback/keepalive (see installInputTapBestEffort).
    private var tapInstalled = false
    /// Set on background/foreground transitions so the watchdog can log app state
    /// without touching UIApplication off the main thread.
    private var inBackground = false

    // MARK: - Session lifecycle

    func startSession(mode: Mode) {
        if sessionActive {
            setMode(mode)
            return
        }
        self.mode = mode
        do {
            try configureSession(active: true)
            enableVoiceProcessing() // before graph/start — changes I/O formats
            connectGraphIfNeeded()
            engine.prepare()
            try engine.start()
            ttsPlayer.play()
            earconPlayer.play()
            startKeepalive()
            sessionActive = true
            startWatchdog()
            // Mic tap is best-effort and installed AFTER the engine is up (Issue 2):
            // the background-audio assertion only needs playback/keepalive, so a
            // momentary mic-unavailable (e.g. right at lock) must not abort the
            // whole session. The watchdog retries the tap if it fails here.
            installInputTapBestEffort()
            os_log("Session started (mode=%{public}@, aec=%d, tap=%d)", log: audioLog, type: .info,
                   mode.rawValue, aecActive ? 1 : 0, tapInstalled ? 1 : 0)
            onEvent?("onSessionStarted", ["mode": mode.rawValue, "aec": aecActive,
                                          "bargeIn": bargeInAvailable])
            enterListening()
        } catch {
            os_log("startSession failed: %{public}@", log: audioLog, type: .error, error.localizedDescription)
            onEvent?("onError", ["where": "startSession", "message": error.localizedDescription])
        }
    }

    func stopSession() {
        guard sessionActive else { return }
        sessionActive = false
        pttCapturing = false
        stopWatchdog()
        endRecoveryHold()
        stopThinkingCue()
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        ttsPlayer.stop()
        earconPlayer.stop()
        keepalivePlayer.stop()
        engine.stop()
        resetVAD()
        try? configureSession(active: false)
        os_log("Session stopped", log: audioLog, type: .info)
        onEvent?("onSessionStopped", [:])
    }

    // MARK: - Background keep-alive probe (diagnostic)

    /// Hold the background-audio assertion with a silent loop ONLY — no mic, no
    /// VAD, no earcons — so a device test can isolate the one open question:
    /// does a running AVAudioEngine keep the WKWebView's JS + WebSocket alive
    /// while the phone is locked? Triggered from JS (relayclient://bgspike).
    func startKeepaliveProbe() {
        guard !sessionActive else { return }
        do {
            if aecActive {
                // VP stays latched on the I/O unit once enabled; it needs a
                // record-capable category or engine.start() throws.
                try configureSession(active: true)
            } else {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio, options: [])
                try session.setActive(true)
            }
            connectGraphIfNeeded()
            engine.prepare()
            try engine.start()
            startKeepalive()
            sessionActive = true
            // Issue 2: run the diagnostic watchdog during the silent probe too, so
            // the onBackgroundDiag heartbeat (and the bgspike overlay) work in the
            // standard probe flow, not only during a real voice session.
            startWatchdog()
            os_log("Keepalive probe started (silent background hold)", log: audioLog, type: .info)
            onEvent?("onSessionStarted", ["mode": "keepalive"])
        } catch {
            os_log("Keepalive probe failed: %{public}@", log: audioLog, type: .error, error.localizedDescription)
            onEvent?("onError", ["where": "keepaliveProbe", "message": error.localizedDescription])
        }
    }

    func stopKeepaliveProbe() { stopSession() }

    func setMode(_ mode: Mode) {
        guard self.mode != mode else { return }
        self.mode = mode
        pttCapturing = false
        resetVAD()
        os_log("Mode -> %{public}@", log: audioLog, type: .info, mode.rawValue)
        enterListening()
    }

    // MARK: - Push-to-talk

    func startCapture() {
        guard sessionActive else { return }
        stopPlayback() // pressing to talk barges in over any playback
        resetVAD()
        pttCapturing = true
        onEvent?("onSpeechStart", [:])
    }

    func stopCapture() {
        guard sessionActive, pttCapturing else { return }
        pttCapturing = false
        let samples = utterance
        utterance = []
        if samples.count >= minUtteranceFrames * frameSamples {
            finalizeUtterance(samples)
        } else {
            onEvent?("onVADMisfire", [:])
        }
    }

    // MARK: - Playback (server TTS chunks)

    /// Decode a server WAV chunk (base64) and queue it for gapless playback.
    /// Chunks arriving while the user is mid-barge-in are stale — they belong to
    /// the reply that was just interrupted and were already in flight over the
    /// WebSocket. Playing one would re-mute the mic mid-utterance.
    func enqueueTTS(base64: String) {
        guard sessionActive, !bargeInCapturing, let data = Data(base64Encoded: base64) else { return }
        guard let buffer = pcmBuffer(fromWav: data) else {
            os_log("enqueueTTS: could not decode WAV chunk", log: audioLog, type: .error)
            return
        }
        playbackLock.lock()
        let startingTurn = !ttsTurnActive
        if startingTurn {
            ttsTurnActive = true
            ttsTurnComplete = false
            isSpeaking = true
        }
        pendingTTSBuffers += 1
        let gen = playbackGeneration
        playbackLock.unlock()

        if startingTurn { onEvent?("onSpeaking", [:]) }
        ttsPlayer.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            self?.onTTSBufferFinished(gen: gen)
        }
        if !ttsPlayer.isPlaying { ttsPlayer.play() }
    }

    /// Server has streamed the last chunk of this response. If the queue has
    /// already drained, finish now; otherwise the final buffer's completion
    /// handler will.
    func endTTSTurn() {
        playbackLock.lock()
        ttsTurnComplete = true
        let drained = ttsTurnActive && pendingTTSBuffers <= 0
        playbackLock.unlock()
        if drained { finishTTSTurn(interrupted: false) }
    }

    /// Barge-in / cancel: drop everything queued and go back to listening.
    func stopPlayback() { cancelPlayback(bargeIn: false) }

    private func cancelPlayback(bargeIn: Bool) {
        playbackLock.lock()
        let wasActive = ttsTurnActive || isSpeaking
        playbackGeneration += 1
        pendingTTSBuffers = 0
        ttsTurnActive = false
        ttsTurnComplete = false
        isSpeaking = false
        playbackLock.unlock()

        ttsPlayer.stop()
        ttsPlayer.play() // keep node hot for the next turn
        if wasActive {
            onEvent?("onPlaybackEnded", ["interrupted": true, "bargeIn": bargeIn])
            // On voice barge-in the user is mid-sentence: no listening earcon
            // over their words — capture is already running.
            if !bargeIn { enterListening() }
        }
    }

    private func onTTSBufferFinished(gen: Int) {
        playbackLock.lock()
        guard gen == playbackGeneration else { playbackLock.unlock(); return }
        pendingTTSBuffers -= 1
        // Only end the turn on a drain if the server has said it's done; an
        // inter-chunk gap must keep us "speaking" (mic stays muted).
        let finishing = pendingTTSBuffers <= 0 && ttsTurnComplete
        playbackLock.unlock()
        if finishing { finishTTSTurn(interrupted: false) }
    }

    private func finishTTSTurn(interrupted: Bool) {
        playbackLock.lock()
        guard ttsTurnActive else { playbackLock.unlock(); return }
        ttsTurnActive = false
        ttsTurnComplete = false
        pendingTTSBuffers = 0
        isSpeaking = false
        playbackLock.unlock()

        onEvent?("onPlaybackEnded", ["interrupted": interrupted, "bargeIn": false])
        enterListening()
    }

    // MARK: - Earcons (synthesized; play through the engine so they're audible backgrounded)

    // MARK: - Thinking cue

    func startThinkingCue() {
        stopThinkingCue()
        guard sessionActive else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 2.4)
        timer.setEventHandler { [weak self] in self?.playEarcon("thinking") }
        thinkingTimer = timer
        timer.resume()
    }

    func stopThinkingCue() {
        thinkingTimer?.cancel()
        thinkingTimer = nil
    }

    func playEarcon(_ name: String) {
        guard sessionActive, let buffer = earconBuffer(name) else { return }
        // Suppress the mic for the earcon's duration (+ a small tail) so the
        // chime can't self-trigger the VAD.
        earconUntil = CFAbsoluteTimeGetCurrent() + Double(buffer.frameLength) / playbackFormat.sampleRate + 0.08
        earconPlayer.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !earconPlayer.isPlaying { earconPlayer.play() }
    }

    /// Hands-free "your turn" cue + event. Chimes only in hands-free (in PTT the
    /// user controls timing, so no chime). Played natively so it still sounds
    /// when the screen is off — the whole point of the eyes-free flow.
    private func enterListening() {
        guard sessionActive, mode == .handsfree, !isSpeaking, !bargeInCapturing else { return }
        playEarcon("listening")
        onEvent?("onListening", [:])
    }

    // MARK: - Audio session

    private func configureSession(active: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if active {
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
        } else {
            // Restore the app's idle default so plain WebView media still plays.
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Enable Apple's voice-processing unit (echo cancellation + noise
    /// suppression) on the engine I/O. Must run while the engine is stopped and
    /// before the graph/tap are built — it changes the hardware I/O formats
    /// (the tap and converter pick the new format up when installed). Enabling
    /// on the input node activates the unit for the whole I/O pair. On failure
    /// we log and stay half-duplex: playback keeps working, barge-in is off.
    private func enableVoiceProcessing() {
        guard !aecActive else { return }
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            aecActive = true
            os_log("Voice processing (AEC) enabled", log: audioLog, type: .info)
        } catch {
            aecActive = false
            os_log("Voice processing unavailable (%{public}@) — barge-in disabled, half-duplex fallback",
                   log: audioLog, type: .error, error.localizedDescription)
        }
    }

    /// Barge-in needs hands-free mode, the feature flag, and working AEC.
    private var bargeInAvailable: Bool { bargeInEnabled && aecActive }

    /// Live tuning from JS (eve's frontend ships without an app rebuild, so the
    /// thresholds can be dialed in on-device). Times are ms, converted to 20 ms
    /// frames. Reads from the audio thread race benignly (word-sized values).
    func setTuning(bargeInEnabled: Bool?, bargeInRmsThreshold: Double?,
                   bargeInWindowMs: Double?, bargeInMinVoicedMs: Double?) {
        if let v = bargeInEnabled { self.bargeInEnabled = v }
        if let v = bargeInRmsThreshold { self.bargeInRmsThreshold = Float(v) }
        if let v = bargeInWindowMs { self.bargeInWindowFrames = max(5, Int(v / 20.0)) }
        if let v = bargeInMinVoicedMs { self.bargeInMinVoicedFrames = max(3, Int(v / 20.0)) }
        os_log("Tuning: bargeIn=%d rms=%.3f window=%df voiced=%df", log: audioLog, type: .info,
               self.bargeInEnabled ? 1 : 0, self.bargeInRmsThreshold,
               self.bargeInWindowFrames, self.bargeInMinVoicedFrames)
    }

    // MARK: - Graph

    /// Attach + connect the playback nodes once. The player→mixer format is
    /// fixed (`playbackFormat`), independent of the mic route, so this never
    /// needs rebuilding — only the input tap does (see `installInputTap`).
    private func connectGraphIfNeeded() {
        guard !graphConnected else { return }
        engine.attach(ttsPlayer)
        engine.attach(earconPlayer)
        engine.attach(keepalivePlayer)
        engine.connect(ttsPlayer, to: engine.mainMixerNode, format: playbackFormat)
        engine.connect(earconPlayer, to: engine.mainMixerNode, format: playbackFormat)
        engine.connect(keepalivePlayer, to: engine.mainMixerNode, format: playbackFormat)
        graphConnected = true
    }

    /// (Re)install the mic tap against the current input hardware format and
    /// rebuild the downsampling converter. Safe to call after a route change.
    private func installInputTap() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw EveAudioError.noInput
        }
        os_log("Input tap installed: %.0f Hz, %d ch", log: audioLog, type: .info,
               inputFormat.sampleRate, Int(inputFormat.channelCount))
        inputConverter = AVAudioConverter(from: inputFormat, to: captureFormat)
        loggedFirstBuffer = false
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.processInput(buffer)
        }
    }

    // MARK: - Interruptions & route changes (Phase 3)

    func observeAudioSession() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        // object: nil (filtered in the handler) — the engine instance is
        // replaced after a media-services reset, which would orphan an
        // object-bound observer.
        nc.addObserver(self, selector: #selector(handleConfigChange(_:)),
                       name: .AVAudioEngineConfigurationChange, object: nil)
        nc.addObserver(self, selector: #selector(handleMediaServicesReset(_:)),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        // Waking the phone must always revive a live session. If we were
        // suspended mid-interruption (long phone call), the .ended notification
        // can be lost — `interrupted` would stay latched and the watchdog would
        // never recover. Foregrounding is the user saying "I'm back".
        nc.addObserver(self, selector: #selector(handleDidBecomeActive(_:)),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
        // Background entry is the critical instant for the audio assertion; the
        // willEnterForeground pairs the bookkeeping. (didBecomeActive above still
        // handles dead-engine recovery on wake.)
        nc.addObserver(self, selector: #selector(handleDidEnterBackground(_:)),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWillEnterForeground(_:)),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func handleDidBecomeActive(_ note: Notification) {
        guard sessionActive, !engine.isRunning else { return }
        os_log("Foregrounded with dead engine — recovering", log: audioLog, type: .info)
        interrupted = false
        attemptRecovery("foreground")
    }

    /// Entering background is the critical instant (Issue 2): if audio isn't
    /// genuinely rendering when the screen locks, iOS suspends within seconds.
    /// Verify output is flowing under a short background-task bridge; release the
    /// bridge immediately if healthy (the audio assertion then carries the process).
    @objc private func handleDidEnterBackground(_ note: Notification) {
        inBackground = true
        guard sessionActive else { return }
        os_log("Entered background — verifying audio is rendering", log: audioLog, type: .info)
        beginRecoveryHold()
        let healthy = ensureRendering("background")
        if healthy { endRecoveryHold() }
        os_log("Background entry: rendering=%d engine=%d keepalive=%d", log: audioLog,
               type: healthy ? .info : .error, healthy ? 1 : 0, engine.isRunning ? 1 : 0,
               keepalivePlayer.isPlaying ? 1 : 0)
    }

    @objc private func handleWillEnterForeground(_ note: Notification) {
        inBackground = false
        guard sessionActive else { return }
        os_log("Will enter foreground", log: audioLog, type: .info)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard sessionActive,
              let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            os_log("Audio interruption began", log: audioLog, type: .info)
            interrupted = true
            // With the screen off the audio assertion is the process's only
            // lifeline; hold a background task so we survive long enough to
            // receive .ended and resume (Siri, alarms, other apps' audio).
            beginRecoveryHold()
            stopPlayback()
            engine.pause()
            onEvent?("onInterruption", ["state": "began"])
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(
                rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            os_log("Audio interruption ended (shouldResume=%d)", log: audioLog, type: .info,
                   opts.contains(.shouldResume) ? 1 : 0)
            interrupted = false
            // Resume regardless of shouldResume: a hands-free conversation is
            // expected to keep listening after Siri/an alarm, and iOS omits the
            // flag in cases that are fine to resume from. If reactivation fails
            // (another app still holds the session) the watchdog retries.
            attemptRecovery("interruption-ended")
            onEvent?("onInterruption", ["state": "ended", "resumed": true])
        @unknown default: break
        }
    }

    /// Bring a stopped/paused engine back to life. Shared by interruption-end,
    /// the watchdog, and foreground recovery. Failure is non-fatal — the
    /// watchdog retries every few seconds while the recovery hold lasts.
    private func attemptRecovery(_ context: String) {
        guard sessionActive else { return }
        do {
            try configureSession(active: true)
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            ttsPlayer.play()
            earconPlayer.play()
            startKeepalive()
            resetVAD()
            // Re-establish the mic if it was lost during the interruption (Issue 2).
            if !tapInstalled { installInputTapBestEffort() }
            endRecoveryHold()
            os_log("Audio recovered (%{public}@)", log: audioLog, type: .info, context)
            enterListening()
        } catch {
            os_log("Recovery failed (%{public}@): %{public}@", log: audioLog, type: .error,
                   context, error.localizedDescription)
            onEvent?("onError", ["where": "recovery", "message": error.localizedDescription])
        }
    }

    /// Media services daemon crashed/reset: the engine and every node are dead
    /// objects. Per Apple's guidance, discard and rebuild the whole graph.
    @objc private func handleMediaServicesReset(_ note: Notification) {
        guard sessionActive else { return }
        os_log("Media services were reset — rebuilding audio engine", log: audioLog, type: .error)
        beginRecoveryHold()
        playbackLock.lock()
        playbackGeneration += 1
        pendingTTSBuffers = 0
        ttsTurnActive = false
        ttsTurnComplete = false
        isSpeaking = false
        playbackLock.unlock()

        engine = AVAudioEngine()
        ttsPlayer = AVAudioPlayerNode()
        earconPlayer = AVAudioPlayerNode()
        keepalivePlayer = AVAudioPlayerNode()
        graphConnected = false
        aecActive = false
        inputConverter = nil
        interrupted = false
        tapInstalled = false
        resetVAD()
        do {
            try configureSession(active: true)
            enableVoiceProcessing()
            connectGraphIfNeeded()
            engine.prepare()
            try engine.start()
            ttsPlayer.play()
            earconPlayer.play()
            startKeepalive()
            installInputTapBestEffort() // mic is best-effort; keepalive must survive (Issue 2)
            endRecoveryHold()
            os_log("Engine rebuilt after media services reset", log: audioLog, type: .info)
            onEvent?("onPlaybackEnded", ["interrupted": true, "bargeIn": false])
            enterListening()
        } catch {
            os_log("Engine rebuild failed: %{public}@", log: audioLog, type: .error,
                   error.localizedDescription)
            onEvent?("onError", ["where": "mediaReset", "message": error.localizedDescription])
            // Recovery hold stays — the watchdog keeps retrying engine.start().
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard sessionActive else { return }
        // A new output route (e.g. Bluetooth car / earbuds) takes over playback
        // automatically; we just inform JS. The engine rebuild for any HW-format
        // change is driven by `handleConfigChange`, the canonical signal.
        let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
        onEvent?("onRouteChange", ["reason": Int(reason)])
    }

    /// The engine's HW format changed (route swap, sample-rate change). The
    /// running graph must be rebuilt or it will assert. This is the documented
    /// place to do it.
    @objc private func handleConfigChange(_ note: Notification) {
        guard sessionActive, !interrupted, (note.object as? AVAudioEngine) === engine else { return }
        os_log("Engine config changed — rebuilding input", log: audioLog, type: .info)
        stopPlayback()
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            ttsPlayer.play()
            earconPlayer.play()
            startKeepalive()
            installInputTapBestEffort() // mic rebuild is best-effort (Issue 2)
            resetVAD()
        } catch {
            onEvent?("onError", ["where": "rebuild", "message": error.localizedDescription])
        }
    }

    // MARK: - Background survival (watchdog + recovery hold)

    /// While a session is live, verify every few seconds that the engine is
    /// actually rendering. A dead engine drops the background-audio assertion
    /// and iOS suspends the app shortly after — the watchdog restarts it within
    /// one tick, under a recovery hold so retries survive with the screen off.
    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdogTimer = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func watchdogTick() {
        guard sessionActive else { return }
        // Diagnostic heartbeat (Issue 2): stamp each tick with the wall-clock gap
        // to the previous one. While the process is suspended these ticks stop,
        // so a gap much larger than the 3 s interval is a recorded suspension —
        // visible in Console.app under the "AudioBridge" category, and emitted to
        // JS as onBackgroundDiag for the on-device overlay.
        let now = CFAbsoluteTimeGetCurrent()
        let gap = lastWatchdogTick > 0 ? now - lastWatchdogTick : 0
        lastWatchdogTick = now
        let rendering = engine.isRunning && keepalivePlayer.isPlaying
        os_log("Watchdog tick: bg=%d rendering=%d engine=%d keepalive=%d tap=%d gap=%.1fs",
               log: audioLog, type: (gap > 6 || !rendering) ? .error : .info,
               inBackground ? 1 : 0, rendering ? 1 : 0, engine.isRunning ? 1 : 0,
               keepalivePlayer.isPlaying ? 1 : 0, tapInstalled ? 1 : 0, gap)
        onEvent?("onBackgroundDiag", ["gapMs": Int(gap * 1000), "rendering": rendering,
                                      "engineRunning": engine.isRunning,
                                      "keepalive": keepalivePlayer.isPlaying,
                                      "inBackground": inBackground])
        guard !interrupted else { return }
        // Re-arm whenever output isn't actually flowing — the engine may be dead
        // OR "running" with a stopped keepalive (the case the old check, which
        // tested only engine.isRunning, missed and which let iOS suspend us).
        if !rendering {
            os_log("Watchdog: output not flowing — re-arming", log: audioLog, type: .error)
            beginRecoveryHold()
            if ensureRendering("watchdog") { endRecoveryHold() }
        } else if !tapInstalled {
            // Output healthy but mic lost; retry the tap so listening resumes
            // (e.g. after a mic-unavailable window at lock).
            installInputTapBestEffort()
        }
    }

    /// UIKit background task bridging audio downtime. `recoveryTask` is only
    /// touched on the main queue.
    private func beginRecoveryHold() {
        DispatchQueue.main.async {
            guard self.recoveryTask == .invalid else { return }
            self.recoveryTask = UIApplication.shared.beginBackgroundTask(withName: "eve-audio-recovery") { [weak self] in
                self?.endRecoveryHold()
            }
            os_log("Recovery hold acquired", log: audioLog, type: .info)
        }
    }

    private func endRecoveryHold() {
        DispatchQueue.main.async {
            guard self.recoveryTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.recoveryTask)
            self.recoveryTask = .invalid
            os_log("Recovery hold released", log: audioLog, type: .info)
        }
    }

    /// Background survival (Issue 2): the single idempotent guarantee that audio
    /// is actually *rendering* while a session is live — the engine running AND
    /// the keepalive node playing. iOS holds the background-audio assertion only
    /// while real output flows, so an engine that reports isRunning==true but
    /// whose keepalive node has stopped goes silent and gets suspended. Returns
    /// true when output is confirmed flowing.
    @discardableResult
    private func ensureRendering(_ context: String) -> Bool {
        guard sessionActive, !interrupted else { return false }
        if !engine.isRunning {
            do {
                try configureSession(active: true)
                engine.prepare()
                try engine.start()
                ttsPlayer.play()
                earconPlayer.play()
                os_log("ensureRendering(%{public}@): restarted dead engine", log: audioLog, type: .error, context)
            } catch {
                os_log("ensureRendering(%{public}@): engine restart failed: %{public}@",
                       log: audioLog, type: .error, context, error.localizedDescription)
                return false
            }
        }
        // The piece the old watchdog missed: confirm the keepalive is actually
        // playing, not merely that the engine object is "running".
        if !keepalivePlayer.isPlaying {
            startKeepalive()
            os_log("ensureRendering(%{public}@): re-armed silent keepalive", log: audioLog, type: .error, context)
        }
        // Mic tap is best-effort and not required for the assertion; retry it
        // here if it dropped, but its absence must not report unhealthy.
        if !tapInstalled { installInputTapBestEffort() }
        return engine.isRunning && keepalivePlayer.isPlaying
    }

    /// Install the mic tap without letting a momentary mic-unavailable (common at
    /// the instant the screen locks) tear down playback/keepalive — the
    /// background assertion only needs output. On failure we stay tap-less and
    /// the watchdog retries; playback + the silent keepalive keep the process
    /// alive meanwhile.
    private func installInputTapBestEffort() {
        do {
            try installInputTap()
            tapInstalled = true
        } catch {
            tapInstalled = false
            os_log("Input tap unavailable (%{public}@) — playback/keepalive continue, watchdog will retry",
                   log: audioLog, type: .error, error.localizedDescription)
        }
    }

    /// A looping near-silent buffer keeps a node actively rendering between
    /// turns, so iOS doesn't suspend the process during conversational pauses.
    private func startKeepalive() {
        keepalivePlayer.stop() // idempotent: avoid stacking loops on resume/rebuild
        let rate = playbackFormat.sampleRate
        let frames = AVAudioFrameCount(rate * 0.5)
        guard let buf = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frames),
              let ch = buf.floatChannelData?[0] else { return }
        buf.frameLength = frames
        // A continuous, near-inaudible tone — NOT pure silence. iOS can suspend a
        // background-audio app whose output it detects as silent, which is what
        // "screen-off works for a bit then stops, resumes on wake" looked like. A
        // low-amplitude 11 kHz sine (~ -64 dBFS) keeps the assertion reliably held.
        // Exactly 5500 cycles per 0.5 s buffer at 24 kHz, so the loop is seamless.
        let n = Int(frames)
        let amp: Float = 0.0006
        for i in 0..<n {
            ch[i] = amp * Float(sin(2.0 * Double.pi * 11000.0 * Double(i) / rate))
        }
        keepalivePlayer.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        keepalivePlayer.play()
    }

    // MARK: - Capture / VAD (audio thread)

    private func processInput(_ buffer: AVAudioPCMBuffer) {
        guard sessionActive else { return }
        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            os_log("First mic buffer: %.0f Hz, %d ch, %d frames", log: audioLog, type: .info,
                   buffer.format.sampleRate, Int(buffer.format.channelCount), Int(buffer.frameLength))
        }
        // Never listen while an earcon is sounding (time-boxed — see earconUntil).
        if CFAbsoluteTimeGetCurrent() < earconUntil { return }
        // While Eve is speaking, hands-free routes frames to the strict barge-in
        // detector (needs AEC so we aren't hearing our own TTS). PTT keeps the
        // mic gated — its barge-in is the talk button (startCapture). Once a
        // barge-in triggers, bargeInCapturing carries us into the normal
        // endpointing path below while isSpeaking flips off asynchronously.
        let bargingIn = isSpeaking && !bargeInCapturing
        if bargingIn, !(mode == .handsfree && bargeInAvailable) { return }
        if mode == .handsfree {
            // listen continuously
        } else if !pttCapturing {
            return
        }
        guard let frames = downsample(buffer) else { return }
        frameAccumulator.append(contentsOf: frames)
        while frameAccumulator.count >= frameSamples {
            let frame = Array(frameAccumulator.prefix(frameSamples))
            frameAccumulator.removeFirst(frameSamples)
            if mode == .ptt {
                utterance.append(contentsOf: frame)
                emitLevel(rms(frame))
            } else if isSpeaking && !bargeInCapturing {
                processFrameBargeIn(frame)
            } else {
                processFrameHandsfree(frame)
            }
        }
    }

    /// Strict gate while Eve is speaking: trigger only on sustained voiced
    /// energy well above the residual-echo floor — `bargeInMinVoicedFrames`
    /// voiced frames within the last `bargeInWindowFrames`. The window (not a
    /// consecutive run) tolerates the internal gaps of real words ("s-t-op")
    /// while still rejecting short grunts and coughs.
    private func processFrameBargeIn(_ frame: [Float]) {
        bargeInRing.append(frame)
        let voiced = rms(frame) > bargeInRmsThreshold
        bargeInVoicedFlags.append(voiced)
        if voiced { bargeInVoicedCount += 1 }
        if bargeInRing.count > bargeInWindowFrames {
            bargeInRing.removeFirst()
            if bargeInVoicedFlags.removeFirst() { bargeInVoicedCount -= 1 }
        }
        guard bargeInVoicedCount >= bargeInMinVoicedFrames else { return }

        os_log("Barge-in: %d voiced / %d window frames — interrupting TTS",
               log: audioLog, type: .info, bargeInVoicedCount, bargeInRing.count)
        // Seed the utterance with the whole window so the words that triggered
        // the barge-in ("stop, actually…") are in the audio sent to STT.
        bargeInCapturing = true
        inSpeech = true
        speechRun = 0
        silenceRun = 0
        utterance = bargeInRing.flatMap { $0 }
        bargeInRing.removeAll()
        bargeInVoicedFlags.removeAll()
        bargeInVoicedCount = 0
        onEvent?("onSpeechStart", [:])
        // Halt playback off the tap callback; player-node stop can block.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.cancelPlayback(bargeIn: true)
        }
    }

    private func processFrameHandsfree(_ frame: [Float]) {
        let level = rms(frame)
        emitLevel(level)
        let isVoiced = level > rmsThreshold

        if !inSpeech {
            preRoll.append(frame)
            if preRoll.count > preRollFrames { preRoll.removeFirst() }
            if isVoiced {
                speechRun += 1
                if speechRun >= startFrames {
                    inSpeech = true
                    silenceRun = 0
                    for f in preRoll { utterance.append(contentsOf: f) }
                    preRoll.removeAll()
                    onEvent?("onSpeechStart", [:])
                }
            } else {
                speechRun = 0
            }
            return
        }

        utterance.append(contentsOf: frame)
        if isVoiced {
            silenceRun = 0
        } else {
            silenceRun += 1
        }
        let frameCount = utterance.count / frameSamples
        if silenceRun >= endSilenceFrames || frameCount >= maxUtteranceFrames {
            let done = utterance
            let voicedEnough = frameCount - silenceRun >= minHandsfreeVoicedFrames
            resetVAD()
            if voicedEnough {
                finalizeUtterance(done)
            } else {
                onEvent?("onVADMisfire", [:])
            }
        }
    }

    private func finalizeUtterance(_ samples: [Float]) {
        os_log("Utterance captured: %d samples (%.2fs)", log: audioLog, type: .info,
               samples.count, Double(samples.count) / 16000.0)
        playEarcon("captured")
        onEvent?("onSpeechEnd", [:])
        finalizeQueue.async { [weak self] in
            guard let self = self else { return }
            let wav = Self.wav16k(from: samples)
            self.onEvent?("onUtterance", ["audio": wav.base64EncodedString()])
        }
    }

    private func resetVAD() {
        frameAccumulator.removeAll()
        preRoll.removeAll()
        utterance.removeAll()
        inSpeech = false
        speechRun = 0
        silenceRun = 0
        bargeInRing.removeAll()
        bargeInVoicedFlags.removeAll()
        bargeInVoicedCount = 0
        bargeInCapturing = false
    }

    private func emitLevel(_ level: Float) {
        levelFrameCounter += 1
        if levelFrameCounter >= levelEmitEveryFrames {
            levelFrameCounter = 0
            // Normalize to a roughly 0..1 range for the orb.
            let norm = min(1.0, level / 0.2)
            onEvent?("onLevel", ["rms": Double(norm)])
        }
    }

    // MARK: - DSP helpers

    private func rms(_ frame: [Float]) -> Float {
        var sum: Float = 0
        for s in frame { sum += s * s }
        return (sum / Float(frame.count)).squareRoot()
    }

    /// Convert an arbitrary-rate input buffer to 16 kHz mono float samples.
    private func downsample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        // Rebuild the converter if the live buffer's format differs from what we
        // built for. Switching to AirPods (or any Bluetooth/USB mic) delivers a
        // different sample rate / channel layout than the built-in mic; a stale
        // converter then yields silence — the "AirPods records nothing" bug.
        if inputConverter?.inputFormat != buffer.format {
            os_log("Input format changed to %.0f Hz, %d ch — rebuilding converter",
                   log: audioLog, type: .info, buffer.format.sampleRate, Int(buffer.format.channelCount))
            inputConverter = AVAudioConverter(from: buffer.format, to: captureFormat)
        }
        guard let converter = inputConverter else { return nil }
        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let err = err {
            os_log("downsample error: %{public}@", log: audioLog, type: .error, err.localizedDescription)
            return nil
        }
        guard let ch = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    /// Build a 16 kHz mono 16-bit PCM WAV from float samples.
    private static func wav16k(from samples: [Float]) -> Data {
        let sampleRate = 16000
        var data = Data(capacity: 44 + samples.count * 2)
        let byteRate = sampleRate * 2
        let dataBytes = samples.count * 2

        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))           // PCM chunk size
        append(UInt16(1))            // audio format = PCM
        append(UInt16(1))            // channels
        append(UInt32(sampleRate))
        append(UInt32(byteRate))
        append(UInt16(2))            // block align
        append(UInt16(16))           // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            append(Int16(clamped * 32767))
        }
        return data
    }

    /// Decode a server WAV chunk (16-bit PCM, usually 24 kHz mono) into a buffer
    /// in `playbackFormat`, resampling if the source rate differs.
    private func pcmBuffer(fromWav data: Data) -> AVAudioPCMBuffer? {
        guard let wav = Self.parseWav(data) else { return nil }
        guard let srcFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(wav.sampleRate),
            channels: AVAudioChannelCount(wav.channels), interleaved: false) else { return nil }

        let srcFrames = wav.pcm.count / (2 * wav.channels)
        guard srcFrames > 0,
              let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(srcFrames))
        else { return nil }
        srcBuffer.frameLength = AVAudioFrameCount(srcFrames)

        wav.pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let ints = raw.bindMemory(to: Int16.self)
            for ch in 0..<wav.channels {
                guard let out = srcBuffer.floatChannelData?[ch] else { continue }
                for f in 0..<srcFrames {
                    out[f] = Float(Int16(littleEndian: ints[f * wav.channels + ch])) / 32768.0
                }
            }
        }

        if wav.sampleRate == Int(playbackFormat.sampleRate) && wav.channels == 1 {
            return srcBuffer
        }
        guard let converter = AVAudioConverter(from: srcFormat, to: playbackFormat) else { return nil }
        let ratio = playbackFormat.sampleRate / srcFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(srcFrames) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return srcBuffer
        }
        return err == nil ? out : nil
    }

    private struct Wav { let sampleRate: Int; let channels: Int; let pcm: Data }

    /// Minimal RIFF/WAVE parser: locates `fmt ` (rate/channels) and `data`
    /// (PCM payload). Tolerant of extra chunks before `data`.
    private static func parseWav(_ data: Data) -> Wav? {
        guard data.count > 44 else { return nil }
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o+1])<<8 | Int(data[o+2])<<16 | Int(data[o+3])<<24 }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o+1])<<8 }
        guard data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46 else { return nil } // "RIFF"

        var sampleRate = 24000, channels = 1
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " && body + 16 <= data.count {
                channels = max(1, u16(body + 2))
                sampleRate = u32(body + 4)
            } else if id == "data" {
                let end = min(data.count, body + size)
                return Wav(sampleRate: sampleRate, channels: channels, pcm: data.subdata(in: body..<end))
            }
            offset = body + size + (size & 1) // chunks are word-aligned
        }
        return nil
    }

    /// Synthesize a short earcon tone buffer (24 kHz mono) with a quick fade so
    /// it never clicks. Distinct tones per state for eyes-free recognition.
    private func earconBuffer(_ name: String) -> AVAudioPCMBuffer? {
        let spec: (freq: Double, ms: Double, freq2: Double?, gain: Double)
        switch name {
        case "listening": spec = (660, 90, nil, 0.22)    // soft single blip — mic open
        case "captured":  spec = (520, 70, nil, 0.22)    // lower confirm — got your speech
        case "thinking":  spec = (480, 55, nil, 0.06)    // faint repeating tick — AI working
        case "error":     spec = (200, 120, 160, 0.22)   // low two-tone — problem
        default:          spec = (600, 80, nil, 0.22)
        }
        let rate = playbackFormat.sampleRate
        let total = AVAudioFrameCount(rate * spec.ms / 1000.0)
        guard total > 0, let buf = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: total),
              let ch = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = total
        let n = Int(total)
        let fade = max(1, n / 8)
        for i in 0..<n {
            let t = Double(i) / rate
            let freq = (spec.freq2 != nil && i > n / 2) ? spec.freq2! : spec.freq
            var amp = spec.gain * sin(2.0 * Double.pi * freq * t)
            if i < fade { amp *= Double(i) / Double(fade) }
            if i > n - fade { amp *= Double(n - i) / Double(fade) }
            ch[i] = Float(amp)
        }
        return buf
    }

    // MARK: - Status

    func getStatus() -> [String: Any] {
        ["sessionActive": sessionActive, "mode": mode.rawValue, "speaking": isSpeaking,
         "engineRunning": engine.isRunning, "aec": aecActive,
         "bargeIn": bargeInAvailable,
         "bargeInRmsThreshold": Double(bargeInRmsThreshold),
         "bargeInWindowMs": bargeInWindowFrames * 20,
         "bargeInMinVoicedMs": bargeInMinVoicedFrames * 20]
    }
}

enum EveAudioError: LocalizedError {
    case noInput
    var errorDescription: String? {
        switch self {
        case .noInput: return "No audio input available (mic not ready)."
        }
    }
}
