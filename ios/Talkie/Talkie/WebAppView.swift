import SwiftUI
import WebKit
import AVFoundation
import FoundationModels
import Security
import SafariServices
import UIKit
import os

private let logger = Logger(subsystem: "com.leonardogracios.talkie", category: "NativeTTS")

// MARK: - Keychain Helper

struct KeychainHelper {
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.talkie.app"
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.talkie.app",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.talkie.app"
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Shared Mic State

class MicState: ObservableObject {
    static let shared = MicState()
    @Published var isListening = false
}


struct WebAppView: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appState = AppState.shared

    /// Mode 0 : suivre le schéma effectif SwiftUI (système), pas seulement le trait du WKWebView.
    private func resolvedAppThemeString() -> String {
        switch appState.appearanceMode {
        case 1: return "light"
        case 2: return "dark"
        default: return colorScheme == .dark ? "dark" : "light"
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        // CRITICAL: Configure audio session for simultaneous playback + recording
        // Without this, iOS switches to "playback" mode after TTS and blocks the mic
        Self.configureAudioSession()

        // Kick off the diarizer model download/load in the background so the first
        // listening session doesn't have to wait. Safe to call repeatedly — it's a
        // no-op once loaded.
        DiarizationManager.shared.prepare()

        // Ask up-front for permission to inject Talkie's voice into calls (iOS 18.2+), so
        // it's granted before the user ever needs it. No-op once the user has decided.
        CallModeManager.shared.requestMicrophoneInjectionPermissionIfNeeded()

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Toujours fixer `data-app-theme` (mode Système = colorScheme environnement).
        let resolvedTheme = resolvedAppThemeString()
        let metaColor = resolvedTheme == "dark" ? "#1C1C1E" : "#F5F6FA"
        let themeSource =
            "document.documentElement.setAttribute('data-app-theme','\(resolvedTheme)');(function(){var m=document.querySelector('meta[name=\"theme-color\"]');if(m)m.content='\(metaColor)';})();"
        let themeScript = WKUserScript(
            source: themeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(themeScript)

        let coordinator = context.coordinator
        config.userContentController.add(coordinator, name: "llmRequest")
        config.userContentController.add(coordinator, name: "resetAudioSession")
        config.userContentController.add(coordinator, name: "playTTSFromData")
        config.userContentController.add(coordinator, name: "stopNativeTTS")
        config.userContentController.add(coordinator, name: "checkLLMAvailability")
        config.userContentController.add(coordinator, name: "keychainSave")
        config.userContentController.add(coordinator, name: "keychainLoad")
        config.userContentController.add(coordinator, name: "keychainDelete")
        config.userContentController.add(coordinator, name: "micStatusUpdate")
        config.userContentController.add(coordinator, name: "openURL")
        config.userContentController.add(coordinator, name: "deactivateAudioSession")
        config.userContentController.add(coordinator, name: "speakApplePersonalVoice")
        config.userContentController.add(coordinator, name: "openNativeSettings")
        config.userContentController.add(coordinator, name: "requestAiConsent")
        config.userContentController.add(coordinator, name: "prepareCallModeTTS")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = true
        webView.backgroundColor = .systemGroupedBackground
        webView.scrollView.backgroundColor = .systemGroupedBackground
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        coordinator.webView = webView
        coordinator.startObservingAudioSessionRecovery()
        CallModeManager.shared.onCallModeChanged = { [weak coordinator] active in
            guard let coordinator else { return }
            let js = "window._callModeChanged && window._callModeChanged(\(active));"
            coordinator.runJavaScript(js)
        }

        if let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            // Grant read access to the entire bundle to avoid sandbox extension errors
            webView.loadFileURL(htmlURL, allowingReadAccessTo: Bundle.main.bundleURL)
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // `colorScheme` change aussi en mode Système quand l’utilisateur bascule iOS clair/sombre.
        let resolvedTheme = resolvedAppThemeString()
        let meta = resolvedTheme == "dark" ? "#1C1C1E" : "#F5F6FA"
        let js = """
        document.documentElement.setAttribute('data-app-theme', '\(resolvedTheme)');
        (function(){var m=document.querySelector('meta[name="theme-color"]');if(m)m.content='\(meta)';})();
        """

        let effectiveDark = resolvedTheme == "dark"
        let bgColor: UIColor = effectiveDark ? .secondarySystemGroupedBackground : .systemGroupedBackground
        uiView.backgroundColor = bgColor
        uiView.scrollView.backgroundColor = bgColor

        Task { @MainActor in
            do {
                _ = try await uiView.evaluateJavaScript(js)
            } catch {
                // Thème best-effort ; échec JS rare (webview pas prête)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Audio Session Management
    //
    // Ne pas appeler `setActive(false)` depuis la page : `deactivateAudioSession` est un no-op.
    // On garde playAndRecord + activate de façon idempotente pour éviter le spam d’interruptions WebKit.

    /// Intentionally a no-op : ne pas appeler `setActive(false)` (interruptions WebKit / micro).
    static func deactivateAudioSession() {}

    /// Ensure playAndRecord category is set and session is active.
    /// Skips redundant activations to avoid triggering WebKit audio interruption notifications.
    private static var audioSessionConfigured = false

    static func resetAudioSessionConfiguration() {
        audioSessionConfigured = false
    }

    static func markAudioSessionConfigured() {
        audioSessionConfigured = true
    }

    static func configureAudioSessionForCurrentMode() {
        resetAudioSessionConfiguration()
        if CallModeManager.shared.isPhoneCallActive {
            // Phone call owns audio — leave session alone until TTS.
            return
        }
        reassertPlayAndRecordSession(force: true)
    }

    static func reassertPlayAndRecordSession(force: Bool = false) {
        if CallModeManager.shared.isPhoneCallActive {
            // Do not reconfigure session while a phone call owns audio — wait for TTS prep.
            return
        }
        let session = AVAudioSession.sharedInstance()
        if audioSessionConfigured && !force { return }
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
            )
            try session.setAllowHapticsAndSystemSoundsDuringRecording(false)
            try session.setActive(true)
            audioSessionConfigured = true
        } catch {
            // Already active with this category — fine
        }
    }

    /// Initial audio session setup at app launch.
    static func configureAudioSession() {
        reassertPlayAndRecordSession()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
        AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
        weak var webView: WKWebView?
        private var audioSessionObservers: [NSObjectProtocol] = []

        /// ElevenLabs MP3 played natively so WebKit never owns playback — fixes mic + SpeechRecognition after TTS.
        private var nativeAudioPlayer: AVAudioPlayer?
        private var nativeAudioEngine: AVAudioEngine?
        private var nativeAudioPlayerNode: AVAudioPlayerNode?
        private var nativeAudioTimePitch: AVAudioUnitTimePitch?
        private var nativeAudioTempURL: URL?
        private var nativePlaybackId: String?
        private var nativeProgressTimer: Timer?
        private var nativeEngineBackupWork: DispatchWorkItem?
        private var nativeSynthesizer = AVSpeechSynthesizer()
        private var nativeSpeechCallbackId: String?
        private var nativeSpeechStartTimer: Timer?

        /// Gain applied to ElevenLabs MP3 playback. ElevenLabs audio is quieter than
        /// AVSpeechSynthesizer output — boost via the mixer (>1.0 only supported by AVAudioEngine).
        private static let elevenLabsGain: Float = 4.0

        override init() {
            super.init()
            nativeSynthesizer.delegate = self
            // iOS 18.2+ adds TTS to calls via *microphone injection*
            // (CallModeManager.prepareForCallModeTTS → setPreferredMicrophoneInjectionMode),
            // which captures the audio the synth plays locally. The legacy
            // `mixToTelephonyUplink` instead diverts the synth to the telephony uplink path —
            // which third-party apps can't use on cellular calls (InsufficientPriority) and
            // which hides the audio from the injection system. Keep it OFF so injection works.
            nativeSynthesizer.mixToTelephonyUplink = false
        }

        /// Préfère l'API `async` de WKWebView (évite l'avertissement « asynchronous alternative »).
        @MainActor
        func runJavaScript(_ script: String) {
            Task { @MainActor [weak self] in
                guard let self, let webView = self.webView else { return }
                do {
                    _ = try await webView.evaluateJavaScript(script)
                } catch {
                    // Best-effort JS execution
                }
            }
        }

        deinit {
            nativeProgressTimer?.invalidate()
            nativeEngineBackupWork?.cancel()
            nativeEngineBackupWork = nil
            nativeAudioPlayer?.stop()
            nativeAudioPlayerNode?.stop()
            nativeAudioEngine?.stop()
            if let url = nativeAudioTempURL { try? FileManager.default.removeItem(at: url) }
            let nc = NotificationCenter.default
            for o in audioSessionObservers { nc.removeObserver(o) }
        }

        private func handlePlayTTSFromData(message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let playbackId = body["playbackId"] as? String,
                  let base64 = body["base64"] as? String,
                  let data = Data(base64Encoded: base64),
                  !data.isEmpty else {
                logger.warning("Invalid or empty payload")
                return
            }
            // Playback rate from JS (1.0 = normal). Clamped — AVAudioUnitTimePitch supports
            // 1/32 ... 32 but anything past 0.5–2.0 sounds artifact-y for speech.
            let requestedRate = (body["rate"] as? Double).map { Float($0) } ?? 1.0
            let rate = max(0.5, min(2.0, requestedRate))
            // Pitch shift in cents (-2400 ... +2400). Used to color the tone (deeper /
            // higher) without changing speed — TimePitch handles rate and pitch
            // independently. Conservative cap to avoid metallic artifacts.
            let requestedPitchCents = (body["pitchCents"] as? Double).map { Float($0) } ?? 0
            let pitchCents = max(-600, min(600, requestedPitchCents))
            stopNativeTTSPlayback(notifyJS: false)
            if CallModeManager.shared.isPhoneCallActive {
                // .playback + microphone injection — the AVAudioEngine output below is what the
                // system adds to the call uplink. Do NOT override to speaker: that fights the
                // call's system-managed route and can break the injection.
                CallModeManager.prepareForCallModeTTS()
            } else {
                WebAppView.reassertPlayAndRecordSession()
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            }

            // Preferred path: AVAudioEngine with mixer gain > 1.0 to compensate for
            // ElevenLabs MP3 being quieter than AVSpeechSynthesizer output.
            if playElevenLabsBoosted(data: data, playbackId: playbackId, rate: rate, pitchCents: pitchCents) {
                return
            }

            // Fallback: AVAudioPlayer at unity gain (no boost possible).
            do {
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                player.volume = 1.0
                nativePlaybackId = playbackId
                nativeAudioPlayer = player
                guard player.prepareToPlay() else {
                    logger.warning("prepareToPlay failed")
                    failNativeTTS(playbackId: playbackId, code: "prepare_failed")
                    return
                }
                player.play()
                startNativeProgressTimer(playbackId: playbackId)
            } catch {
                logger.error("AVAudioPlayer error: \(error.localizedDescription)")
                failNativeTTS(playbackId: playbackId, code: "decode_failed")
            }
        }

        /// Plays ElevenLabs MP3 through AVAudioEngine so we can apply gain > 1.0
        /// (AVAudioPlayer.volume is clamped to 1.0). Returns false if engine setup fails;
        /// caller falls back to AVAudioPlayer.
        private func playElevenLabsBoosted(data: Data, playbackId: String, rate: Float, pitchCents: Float) -> Bool {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("talkie_tts_\(UUID().uuidString).mp3")
            do {
                try data.write(to: tempURL)
                let audioFile = try AVAudioFile(forReading: tempURL)
                let engine = AVAudioEngine()
                let playerNode = AVAudioPlayerNode()
                let timePitch = AVAudioUnitTimePitch()
                timePitch.rate = rate
                timePitch.pitch = pitchCents
                engine.attach(playerNode)
                engine.attach(timePitch)
                // Chain: player → time-pitch (changes speed without altering pitch) → mixer
                engine.connect(playerNode, to: timePitch, format: audioFile.processingFormat)
                engine.connect(timePitch, to: engine.mainMixerNode, format: audioFile.processingFormat)
                engine.mainMixerNode.outputVolume = WebAppView.Coordinator.elevenLabsGain
                engine.prepare()
                try engine.start()

                nativePlaybackId = playbackId
                nativeAudioEngine = engine
                nativeAudioPlayerNode = playerNode
                nativeAudioTimePitch = timePitch
                nativeAudioTempURL = tempURL

                // .dataPlayedBack fires when audio has actually finished playing through
                // the output, not just when the engine consumed the buffer — avoids cutting
                // off the tail of short phrases (the default callback fires too early).
                playerNode.scheduleFile(audioFile, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        // Ignore late callback if a newer playback has started.
                        guard self.nativePlaybackId == playbackId else { return }
                        self.nativeEngineBackupWork?.cancel()
                        self.nativeEngineBackupWork = nil
                        self.finishEnginePlayback(playbackId: playbackId, success: true)
                    }
                }
                playerNode.play()

                // Secours si .dataPlayedBack ne se déclenche pas (texte long / time-pitch).
                let frameCount = Double(audioFile.length)
                let sampleRate = audioFile.processingFormat.sampleRate
                let durationSec = frameCount / sampleRate / Double(max(0.5, rate))
                let backup = DispatchWorkItem { [weak self] in
                    guard let self, self.nativePlaybackId == playbackId else { return }
                    self.finishEnginePlayback(playbackId: playbackId, success: true)
                }
                nativeEngineBackupWork = backup
                DispatchQueue.main.asyncAfter(deadline: .now() + durationSec + 3.0, execute: backup)
                return true
            } catch {
                logger.error("AVAudioEngine setup failed: \(error.localizedDescription) — falling back to AVAudioPlayer")
                try? FileManager.default.removeItem(at: tempURL)
                return false
            }
        }

        private func finishEnginePlayback(playbackId: String, success: Bool) {
            nativeProgressTimer?.invalidate()
            nativeProgressTimer = nil
            nativeEngineBackupWork?.cancel()
            nativeEngineBackupWork = nil
            nativeAudioPlayerNode?.stop()
            nativeAudioEngine?.stop()
            nativeAudioPlayerNode = nil
            nativeAudioEngine = nil
            nativeAudioTimePitch = nil
            if let url = nativeAudioTempURL {
                try? FileManager.default.removeItem(at: url)
                nativeAudioTempURL = nil
            }
            nativePlaybackId = nil
            WebAppView.reassertPlayAndRecordSession()
            let errArg = success ? "null" : "'playback_failed'"
            let js = "window._nativeTTSPlayback && window._nativeTTSPlayback('\(playbackId)', \(errArg));"
            DispatchQueue.main.async { [weak self] in
                self?.runJavaScript(js)
            }
        }

        private func failNativeTTS(playbackId: String, code: String) {
            nativeProgressTimer?.invalidate()
            nativeProgressTimer = nil
            nativeEngineBackupWork?.cancel()
            nativeEngineBackupWork = nil
            nativeAudioPlayer = nil
            nativeAudioPlayerNode?.stop()
            nativeAudioEngine?.stop()
            nativeAudioPlayerNode = nil
            nativeAudioEngine = nil
            nativeAudioTimePitch = nil
            if let url = nativeAudioTempURL {
                try? FileManager.default.removeItem(at: url)
                nativeAudioTempURL = nil
            }
            nativePlaybackId = nil
            WebAppView.reassertPlayAndRecordSession()
            let js = "window._nativeTTSPlayback && window._nativeTTSPlayback('\(playbackId)', '\(code)');"
            DispatchQueue.main.async { [weak self] in
                self?.runJavaScript(js)
            }
        }

        /// - Parameter notifyJS: When stopping from JS `stopAudio`, tell the page so it can clear UI.
        private func stopNativeTTSPlayback(notifyJS: Bool) {
            nativeProgressTimer?.invalidate()
            nativeProgressTimer = nil
            nativeEngineBackupWork?.cancel()
            nativeEngineBackupWork = nil
            nativeSpeechStartTimer?.invalidate()
            nativeSpeechStartTimer = nil
            nativeAudioPlayer?.stop()
            nativeAudioPlayer = nil
            nativeAudioPlayerNode?.stop()
            nativeAudioEngine?.stop()
            nativeAudioPlayerNode = nil
            nativeAudioEngine = nil
            nativeAudioTimePitch = nil
            if let url = nativeAudioTempURL {
                try? FileManager.default.removeItem(at: url)
                nativeAudioTempURL = nil
            }
            let id = nativePlaybackId
            nativePlaybackId = nil

            if nativeSynthesizer.isSpeaking {
                nativeSynthesizer.stopSpeaking(at: .immediate)
            }

            // Also clear Personal Voice callback — the JS side already hides the overlay,
            // but we must nil this out so didCancel (from stopSpeaking above) doesn't
            // try to call a stale JS callback.
            let speechId = nativeSpeechCallbackId
            nativeSpeechCallbackId = nil

            WebAppView.reassertPlayAndRecordSession()
            if notifyJS, let id = id {
                let js = "window._nativeTTSPlayback && window._nativeTTSPlayback('\(id)', 'stopped');"
                DispatchQueue.main.async { [weak self] in
                    self?.runJavaScript(js)
                }
            }
            // If we had a Personal Voice speech in progress, notify JS it's cancelled
            if notifyJS, let speechId = speechId {
                let js = "window._nativeSpeechCallback && window._nativeSpeechCallback('\(speechId)', 'cancelled');"
                DispatchQueue.main.async { [weak self] in
                    self?.runJavaScript(js)
                }
            }
        }

        private func startNativeProgressTimer(playbackId: String) {
            nativeProgressTimer?.invalidate()
            let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                guard let self, let p = self.nativeAudioPlayer else { return }
                let cur = p.currentTime
                let dur = max(p.duration, 0.001)
                let js = "window._nativeTTSProgress && window._nativeTTSProgress('\(playbackId)', \(cur), \(dur))"
                DispatchQueue.main.async { self.runJavaScript(js) }
            }
            RunLoop.main.add(t, forMode: .common)
            nativeProgressTimer = t
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            nativeProgressTimer?.invalidate()
            nativeProgressTimer = nil
            nativeAudioPlayer = nil
            let id = nativePlaybackId
            nativePlaybackId = nil
            WebAppView.reassertPlayAndRecordSession()
            guard let id = id else { return }
            let errArg = flag ? "null" : "'playback_failed'"
            let js = "window._nativeTTSPlayback && window._nativeTTSPlayback('\(id)', \(errArg));"
            DispatchQueue.main.async { [weak self] in
                self?.runJavaScript(js)
            }
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            logger.error("Decode error: \(error?.localizedDescription ?? "?", privacy: .public)")
            let id = nativePlaybackId ?? ""
            nativeProgressTimer?.invalidate()
            nativeProgressTimer = nil
            nativeAudioPlayer = nil
            nativePlaybackId = nil
            WebAppView.reassertPlayAndRecordSession()
            if !id.isEmpty {
                let js = "window._nativeTTSPlayback && window._nativeTTSPlayback('\(id)', 'decode_failed');"
                DispatchQueue.main.async { [weak self] in
                    self?.runJavaScript(js)
                }
            }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
            // Speech actually began — cancel the start-failure timer
            nativeSpeechStartTimer?.invalidate()
            nativeSpeechStartTimer = nil
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            nativeSpeechStartTimer?.invalidate()
            nativeSpeechStartTimer = nil
            guard let id = nativeSpeechCallbackId else { return }
            nativeSpeechCallbackId = nil
            let js = "window._nativeSpeechCallback && window._nativeSpeechCallback('\(id)', null);"
            DispatchQueue.main.async { [weak self] in
                self?.runJavaScript(js)
            }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            nativeSpeechStartTimer?.invalidate()
            nativeSpeechStartTimer = nil
            guard let id = nativeSpeechCallbackId else { return }
            nativeSpeechCallbackId = nil
            let js = "window._nativeSpeechCallback && window._nativeSpeechCallback('\(id)', 'cancelled');"
            DispatchQueue.main.async { [weak self] in
                self?.runJavaScript(js)
            }
        }

        func startObservingAudioSessionRecovery() {
            guard audioSessionObservers.isEmpty else { return }
            let nc = NotificationCenter.default
            audioSessionObservers.append(nc.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] note in
                guard let info = note.userInfo,
                      let type = info[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    // Phone call or Siri — CallKit observer handles call mode; reconfigure if needed.
                    return
                }
                guard type == AVAudioSession.InterruptionType.ended.rawValue else { return }
                guard self?.nativeAudioPlayer == nil,
                      self?.nativeAudioEngine == nil,
                      self?.nativeSynthesizer.isSpeaking != true else { return }
                WebAppView.configureAudioSessionForCurrentMode()
            })
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "resetAudioSession" {
                WebAppView.configureAudioSessionForCurrentMode()
                return
            }
            if message.name == "prepareCallModeTTS" {
                CallModeManager.prepareForCallModeTTS()
                return
            }
            if message.name == "playTTSFromData" {
                handlePlayTTSFromData(message: message)
                return
            }
            if message.name == "stopNativeTTS" {
                stopNativeTTSPlayback(notifyJS: true)
                return
            }
            if message.name == "checkLLMAvailability" {
                Task { @MainActor [weak self] in
                    let model = SystemLanguageModel.default
                    let (available, reason): (Bool, String) = {
                        switch model.availability {
                        case .available:
                            return (true, "")
                        case .unavailable(let r):
                            let code: String
                            switch r {
                            case .deviceNotEligible: code = "device_not_eligible"
                            case .appleIntelligenceNotEnabled: code = "apple_intelligence_disabled"
                            case .modelNotReady: code = "model_not_ready"
                            @unknown default: code = "unavailable"
                            }
                            return (false, code)
                        @unknown default:
                            return (false, "unavailable")
                        }
                    }()
                    logger.info("Apple Intelligence availability: \(available, privacy: .public) reason=\(reason, privacy: .public)")
                    let js = "window._llmAvailabilityCallback(\(available), '\(reason)');"
                    self?.runJavaScript(js)
                }
                return
            }
            if message.name == "keychainSave" {
                guard let body = message.body as? [String: Any],
                      let key = body["key"] as? String,
                      let value = body["value"] as? String else { return }
                let ok = KeychainHelper.save(key: key, value: value)
                let js = "window._keychainCallback && window._keychainCallback('save', '\(key)', \(ok));"
                DispatchQueue.main.async { [weak self] in
                    self?.runJavaScript(js)
                }
                return
            }
            if message.name == "keychainLoad" {
                guard let body = message.body as? [String: Any],
                      let key = body["key"] as? String else { return }
                let val = KeychainHelper.load(key: key)
                let escaped = (val ?? "")
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                let js = val != nil
                    ? "window._keychainCallback && window._keychainCallback('load', '\(key)', '\(escaped)');"
                    : "window._keychainCallback && window._keychainCallback('load', '\(key)', null);"
                DispatchQueue.main.async { [weak self] in
                    self?.runJavaScript(js)
                }
                return
            }
            if message.name == "deactivateAudioSession" {
                WebAppView.deactivateAudioSession()
                return
            }
            if message.name == "speakApplePersonalVoice" {
                guard let body = message.body as? [String: Any],
                      let text = body["text"] as? String,
                      let requestId = body["requestId"] as? String else { return }

                let lang = (body["lang"] as? String) ?? "fr-FR"
                if CallModeManager.shared.isPhoneCallActive {
                    CallModeManager.prepareForCallModeTTS()
                } else {
                    WebAppView.reassertPlayAndRecordSession()
                    try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
                }
                nativeSpeechCallbackId = requestId
                // Sanitize text aggressively — éviter toute ressemblance SSML / balises (logs « root tag speak »).
                var sanitized = text
                    .replacingOccurrences(of: "&", with: lang.hasPrefix("fr") ? " et " : " and ")
                    .replacingOccurrences(of: "<", with: " ")
                    .replacingOccurrences(of: ">", with: " ")
                    .replacingOccurrences(of: "\u{00AB}", with: " ")
                    .replacingOccurrences(of: "\u{00BB}", with: " ")
                    .replacingOccurrences(of: "\"", with: " ")
                    .replacingOccurrences(of: "'", with: "\u{2019}")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                if let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
                    let range = NSRange(sanitized.startIndex..., in: sanitized)
                    sanitized = tagRegex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: " ")
                }
                sanitized = sanitized
                    .replacingOccurrences(of: "  ", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                while sanitized.contains("  ") {
                    sanitized = sanitized.replacingOccurrences(of: "  ", with: " ")
                }
                if sanitized.isEmpty {
                    sanitized = "…"
                }

                // Use plain text utterance — never SSML
                let utterance = AVSpeechUtterance(string: sanitized)
                utterance.volume = 1.0
                // Rate / pitch from JS (clamped to safe ranges); defaults preserved if missing.
                let requestedRate = (body["rate"] as? Double).map { Float($0) } ?? Float(AVSpeechUtteranceDefaultSpeechRate)
                utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, requestedRate))
                let requestedPitch = (body["pitchMultiplier"] as? Double).map { Float($0) } ?? 1.0
                utterance.pitchMultiplier = max(0.5, min(2.0, requestedPitch))

                let usePersonalVoice = body["usePersonalVoice"] as? Bool ?? false

                // Pick voice first, then speak — Personal Voice only when user opted in.
                let voice = AVSpeechSynthesisVoice(language: lang)
                utterance.voice = voice

                AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if usePersonalVoice,
                           status == .authorized,
                           let personalVoice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.voiceTraits.contains(.isPersonalVoice) }) {
                            utterance.voice = personalVoice
                        }
                        // The synth must play through the APP audio session — the one
                        // prepareForCallModeTTS puts into .playback + microphone-injection mode — so
                        // the system can add that playback to the call's mic uplink.
                        self.nativeSynthesizer.usesApplicationAudioSession = true
                        self.nativeSynthesizer.mixToTelephonyUplink = false
                        self.nativeSynthesizer.speak(utterance)
                        // Safety: if didStart doesn't fire, notify JS. During a call the audio
                        // session setup + telephony routing is slower, so give it a longer
                        // grace period before declaring failure (1.5s was tripping mid-call).
                        let startTimeout: TimeInterval = CallModeManager.shared.isPhoneCallActive ? 4.0 : 1.5
                        self.nativeSpeechStartTimer?.invalidate()
                        self.nativeSpeechStartTimer = Timer.scheduledTimer(withTimeInterval: startTimeout, repeats: false) { [weak self] _ in
                            guard let self, let id = self.nativeSpeechCallbackId else { return }
                            logger.warning("AVSpeechSynthesizer did not start within \(startTimeout, privacy: .public)s — notifying JS")
                            self.nativeSpeechCallbackId = nil
                            self.nativeSpeechStartTimer = nil
                            if self.nativeSynthesizer.isSpeaking {
                                self.nativeSynthesizer.stopSpeaking(at: .immediate)
                            }
                            let fresh = AVSpeechSynthesizer()
                            fresh.delegate = self
                            fresh.mixToTelephonyUplink = false
                            self.nativeSynthesizer = fresh
                            let js = "window._nativeSpeechCallback && window._nativeSpeechCallback('\(id)', 'start_failed');"
                            DispatchQueue.main.async { [weak self] in
                                self?.runJavaScript(js)
                            }
                        }
                    }
                }
                return
            }
            if message.name == "openURL" {
                if let urlString = message.body as? String,
                   let url = URL(string: urlString) {
                    if url.scheme == "mailto" {
                        Task { @MainActor in
                            _ = await UIApplication.shared.open(url)
                        }
                    } else if let vc = webView?.window?.rootViewController {
                        let safari = SFSafariViewController(url: url)
                        vc.present(safari, animated: true)
                    }
                }
                return
            }
            if message.name == "micStatusUpdate" {
                if let body = message.body as? [String: Any],
                   let listening = body["listening"] as? Bool {
                    DispatchQueue.main.async { [weak self] in
                        MicState.shared.isListening = listening
                        // Never start diarization during a phone call — mic is unavailable
                        // and AVAudioEngine conflicts with the call audio session.
                        if CallModeManager.shared.isPhoneCallActive {
                            if listening {
                                DiarizationManager.shared.stop()
                            }
                            return
                        }
                        if listening {
                            DiarizationManager.shared.onSpeakerChange = { [weak self] fluidId, startSec in
                                let js = "window._diarizationSpeakerChange && window._diarizationSpeakerChange('\(fluidId)', \(startSec));"
                                self?.runJavaScript(js)
                            }
                            DiarizationManager.shared.onStatusChange = { [weak self] status in
                                let js = "window._diarizationStatus && window._diarizationStatus('\(status)');"
                                self?.runJavaScript(js)
                            }
                            // Fire the current status immediately so the web layer can show
                            // "loading" / "ready" without waiting for the next transition.
                            let cur = DiarizationManager.shared.statusString
                            self?.runJavaScript("window._diarizationStatus && window._diarizationStatus('\(cur)');")
                            DiarizationManager.shared.start()
                        } else {
                            DiarizationManager.shared.stop()
                        }
                    }
                }
                return
            }
            if message.name == "keychainDelete" {
                guard let body = message.body as? [String: Any],
                      let key = body["key"] as? String else { return }
                KeychainHelper.delete(key: key)
                let js = "window._keychainCallback && window._keychainCallback('delete', '\(key)', true);"
                DispatchQueue.main.async { [weak self] in
                    self?.runJavaScript(js)
                }
                return
            }

            if message.name == "openNativeSettings" {
                Task { @MainActor [weak self] in
                    self?.openNativeSettings()
                }
                return
            }

            if message.name == "requestAiConsent" {
                Task { @MainActor [weak self] in
                    self?.presentNativeAiConsent(from: message.body)
                }
                return
            }

            guard message.name == "llmRequest",
                  let body = message.body as? [String: Any],
                  let requestId = body["requestId"] as? String,
                  let prompt = body["prompt"] as? String else {
                return
            }

            Task {
                await generateWithAppleLLM(requestId: requestId, body: body, prompt: prompt)
            }
        }

        @MainActor
        private func deliverLLMResult(requestId: String, text: String?, error: String?) async {
            guard let webView else { return }
            let escaped: String
            if let text {
                escaped = text
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "")
            } else {
                escaped = ""
            }
            let errPart: String
            if let error {
                errPart = error
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
            } else {
                errPart = "null"
            }
            let js = text != nil
                ? "window._llmCallback('\(requestId)', '\(escaped)', null);"
                : "window._llmCallback('\(requestId)', null, '\(errPart)');"
            do {
                _ = try await webView.evaluateJavaScript(js)
            } catch {
                logger.error("Failed to send LLM result to web: \(error.localizedDescription)")
            }
        }

        @MainActor
        func generateWithAppleLLM(requestId: String, body: [String: Any], prompt: String) async {
            let structured = body["structured"] as? Bool ?? false
            let minimal = body["minimal"] as? Bool ?? false
            let language = (body["language"] as? String) ?? "fr"
            let richContext = (body["richContext"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let systemPrompt = (body["systemPrompt"] as? String) ?? ""

            switch SystemLanguageModel.default.availability {
            case .available:
                break
            case .unavailable(let reason):
                let code: String
                switch reason {
                case .deviceNotEligible: code = "device_not_eligible"
                case .appleIntelligenceNotEnabled: code = "apple_intelligence_disabled"
                case .modelNotReady: code = "model_not_ready"
                @unknown default: code = "unavailable"
                }
                logger.warning("LLM unavailable: \(code, privacy: .public)")
                await deliverLLMResult(requestId: requestId, text: nil, error: code)
                return
            @unknown default:
                await deliverLLMResult(requestId: requestId, text: nil, error: "unavailable")
                return
            }

            if structured {
                await generateStructuredSuggestions(
                    requestId: requestId,
                    prompt: prompt,
                    language: language,
                    richContext: richContext,
                    minimal: minimal
                )
                return
            }

            // Freeform path (memory extraction, etc.)
            var instructions = TalkieLLMInstructions.trimmed(systemPrompt)
            if instructions.isEmpty {
                instructions = TalkieLLMInstructions.base(language: language, minimal: true)
            }

            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: prompt)
                let text = response.content
                if TalkieLLMInstructions.isRefusal(text) {
                    await deliverLLMResult(requestId: requestId, text: nil, error: "refusal")
                    return
                }
                await deliverLLMResult(requestId: requestId, text: text, error: nil)
            } catch {
                logger.error("LanguageModelSession.respond failed: \(String(describing: error), privacy: .public)")
                await deliverLLMResult(requestId: requestId, text: nil, error: error.localizedDescription)
            }
        }

        @MainActor
        private func generateStructuredSuggestions(
            requestId: String,
            prompt: String,
            language: String,
            richContext: String,
            minimal: Bool
        ) async {
            var instructions = TalkieLLMInstructions.base(language: language, minimal: minimal)
            if !minimal, !richContext.isEmpty {
                instructions += "\n\n" + richContext
            }
            instructions = TalkieLLMInstructions.trimmed(instructions)

            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: prompt, generating: TalkieSuggestions.self)
                let s = response.content
                let lines = [s.direct, s.warm, s.followUp]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                if lines.isEmpty {
                    await deliverLLMResult(requestId: requestId, text: nil, error: "empty")
                    return
                }

                let joined = lines.joined(separator: "\n")
                if TalkieLLMInstructions.isRefusal(joined) {
                    if !minimal {
                        await generateStructuredSuggestions(
                            requestId: requestId,
                            prompt: prompt,
                            language: language,
                            richContext: "",
                            minimal: true
                        )
                        return
                    }
                    await deliverLLMResult(requestId: requestId, text: nil, error: "refusal")
                    return
                }

                await deliverLLMResult(requestId: requestId, text: joined, error: nil)
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .refusal(_, _):
                    logger.warning("Structured suggestion refusal — retrying minimal")
                    if !minimal {
                        await generateStructuredSuggestions(
                            requestId: requestId,
                            prompt: prompt,
                            language: language,
                            richContext: "",
                            minimal: true
                        )
                    } else {
                        await deliverLLMResult(requestId: requestId, text: nil, error: "refusal")
                    }
                default:
                    logger.error("GenerationError: \(String(describing: error), privacy: .public)")
                    await deliverLLMResult(requestId: requestId, text: nil, error: String(describing: error))
                }
            } catch {
                logger.error("Structured respond failed: \(String(describing: error), privacy: .public)")
                await deliverLLMResult(requestId: requestId, text: nil, error: error.localizedDescription)
            }
        }

        // MARK: - Native Settings Bridge

        @MainActor
        private func openNativeSettings() {
            guard let webView = self.webView else { return }
            let js = """
            JSON.stringify({
                memory: state.memory || '',
                learnedMemory: state.learnedMemory || '',
                lang: state.lang || currentLang || 'fr',
                useApplePersonalVoice: state.useApplePersonalVoice,
                useElevenLabs: state.useElevenLabs,
                elApiKey: state.elApiKey || '',
                voiceId: state.voiceId || '',
                hasELConsent: !!localStorage.getItem('talkie_el_consent'),
                hasAiConsent: !!localStorage.getItem('talkie_ai_consent'),
                llmEnabled: state.llmEnabled !== false,
                quickPhrases: state.quickPhrases || []
            })
            """
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await webView.evaluateJavaScript(js)
                    guard let jsonStr = result as? String,
                          let data = jsonStr.data(using: .utf8),
                          let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        self.presentNativeSettings()
                        return
                    }
                    let vm = SettingsViewModel.shared
                    vm.memory = dict["memory"] as? String ?? ""
                    vm.learnedMemory = dict["learnedMemory"] as? String ?? ""
                    vm.lang = dict["lang"] as? String ?? "fr"
                    vm.useApplePersonalVoice = dict["useApplePersonalVoice"] as? Bool ?? false
                    vm.useElevenLabs = dict["useElevenLabs"] as? Bool ?? false
                    vm.elApiKey = dict["elApiKey"] as? String ?? ""
                    if vm.elApiKey.isEmpty, let k = KeychainHelper.load(key: "elApiKey"), !k.isEmpty {
                        vm.elApiKey = k
                    }
                    vm.voiceId = dict["voiceId"] as? String ?? ""
                    vm.hasELConsent = dict["hasELConsent"] as? Bool ?? false
                    vm.llmEnabled = dict["llmEnabled"] as? Bool ?? true
                    vm.hasAiConsent = dict["hasAiConsent"] as? Bool ?? false
                    if let qpArray = dict["quickPhrases"] as? [[String: Any]] {
                        vm.quickPhrases = qpArray.compactMap { d in
                            guard let emoji = d["emoji"] as? String,
                                  let text = d["text"] as? String else { return nil }
                            return QuickPhrase(emoji: emoji, text: text)
                        }
                    } else {
                        vm.quickPhrases = []
                    }
                    self.presentNativeSettings()
                } catch {
                    self.presentNativeSettings()
                }
            }
        }

        @MainActor
        private func presentNativeSettings() {
            let vm = SettingsViewModel.shared

            vm.onDismiss = { [weak self] in
                self?.syncSettingsToJS()
                self?.runJavaScript("loadSettings();")
                let restartJs = "if (userHasInteracted) startListening();"
                self?.runJavaScript(restartJs)
            }

            vm.onClearLearnedMemory = { [weak self] in
                self?.runJavaScript("state.learnedMemory = ''; save();")
            }

            vm.onLanguageChanged = { [weak self] newLang in
                let js = "window.changeLanguage && window.changeLanguage('\(newLang)');"
                self?.runJavaScript(js)
            }

            vm.onReplayTutorial = { [weak self] in
                self?.syncSettingsToJS()
                let js = """
                localStorage.removeItem('talkie_onboarded');
                onbPage = 0;
                document.querySelectorAll('.onb-page').forEach(p => p.classList.remove('active'));
                document.querySelector('.onb-page[data-page="0"]').classList.add('active');
                $('onboarding').classList.remove('hidden');
                """
                self?.runJavaScript(js)
            }

            vm.onResetAll = { [weak self] in
                let js = """
                keychainDelete('elApiKey');
                localStorage.removeItem('talkie_el_consent');
                localStorage.removeItem('talkie_ai_consent');
                localStorage.removeItem('talkie_ai_consent_declined');
                localStorage.removeItem('talkie_voice_clone_consent');
                localStorage.removeItem('talkie_v1');
                localStorage.removeItem('talkie_onboarded');
                ['echo_v5','echo_v4','echo_v3','echo_v2','echo_v1','echo_onboarded'].forEach(k => localStorage.removeItem(k));
                location.reload();
                """
                self?.runJavaScript(js)
            }

            vm.onOpenVoiceCloning = { [weak self] in
                self?.syncSettingsToJS()
                let js = "loadSettings(); showVoiceCloningOnly();"
                self?.runJavaScript(js)
            }

            vm.onTextSizeChanged = { [weak self] pct in
                let js = "window._setTextSize && window._setTextSize(\(pct));"
                self?.runJavaScript(js)
            }

            vm.onQuickPhrasesChanged = { [weak self] phrases in
                guard let jsonData = try? JSONEncoder().encode(phrases),
                      let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
                let escaped = jsonStr
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                let js = "window._updateQuickPhrases && window._updateQuickPhrases('\(escaped)');"
                self?.runJavaScript(js)
            }

            vm.onOledModeChanged = { [weak self] enabled in
                let js = "window._setOledMode && window._setOledMode(\(enabled));"
                self?.runJavaScript(js)
            }

            vm.onOpenProfilePage = { [weak self] in
                // The sheet calls `dismiss()` before us. Give SwiftUI a tick to tear down
                // the settings sheet before swapping to the in-app profile page, otherwise
                // the page renders behind the dismissing sheet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.runJavaScript("window._openProfilePage && window._openProfilePage();")
                }
            }

            vm.onAiConsentResolved = { [weak self] accepted in
                let vm = SettingsViewModel.shared
                if accepted {
                    vm.hasAiConsent = true
                    vm.llmEnabled = true
                } else {
                    vm.hasAiConsent = false
                    vm.llmEnabled = false
                }
                self?.syncSettingsToJS()
            }

            AppState.shared.showSettings = true
        }

        @MainActor
        private func presentNativeAiConsent(from body: Any?) {
            let lang: String
            if let dict = body as? [String: Any], let l = dict["lang"] as? String, !l.isEmpty {
                lang = l
            } else {
                lang = SettingsViewModel.shared.lang
            }

            AppState.shared.aiConsentLang = lang
            AppState.shared.aiConsentCompletion = { [weak self] accepted in
                let vm = SettingsViewModel.shared
                vm.hasAiConsent = accepted
                vm.llmEnabled = accepted
                vm.lang = lang

                var js = "window._aiConsentCallback && window._aiConsentCallback(\(accepted));"
                if accepted {
                    js += """
                    localStorage.setItem('talkie_ai_consent', '1');
                    localStorage.removeItem('talkie_ai_consent_declined');
                    state.llmEnabled = true;
                    """
                } else {
                    js += """
                    localStorage.removeItem('talkie_ai_consent');
                    localStorage.setItem('talkie_ai_consent_declined', '1');
                    state.llmEnabled = false;
                    """
                }
                js += """
                save();
                if ($('aiSuggestionsToggleBtn')) $('aiSuggestionsToggleBtn').classList.toggle('active', state.llmEnabled && !!localStorage.getItem('talkie_ai_consent'));
                if ($('aiAttribution')) $('aiAttribution').style.display = (llmAvailable && !!localStorage.getItem('talkie_ai_consent') && state.llmEnabled !== false) ? 'block' : 'none';
                """
                self?.runJavaScript(js)
                AppState.shared.aiConsentCompletion = nil
                AppState.shared.showAiConsent = false
            }
            AppState.shared.showAiConsent = true
        }

        private func syncSettingsToJS() {
            let vm = SettingsViewModel.shared
            // Keychain côté natif : fiable même si le `keychainSave` via JS est retardé ou asynchrone.
            if vm.elApiKey.isEmpty {
                KeychainHelper.delete(key: "elApiKey")
            } else {
                _ = KeychainHelper.save(key: "elApiKey", value: vm.elApiKey)
            }

            let memory = Self.escapeForJavaScript(vm.memory)
            let learnedMemory = Self.escapeForJavaScript(vm.learnedMemory)
            let voiceId = Self.escapeForJavaScript(vm.voiceId)
            let elKey = Self.escapeForJavaScript(vm.elApiKey)

            let lang = Self.escapeForJavaScript(vm.lang)

            var js = """
            state.elApiKey = '\(elKey)';
            state.memory = '\(memory)';
            state.learnedMemory = '\(learnedMemory)';
            state.useApplePersonalVoice = \(vm.useApplePersonalVoice);
            state.useElevenLabs = \(vm.useElevenLabs);
            state.voiceId = '\(voiceId)';
            currentLang = '\(lang)';
            if (window.changeLanguage && currentLang !== state.lang) {
                window.changeLanguage('\(lang)');
            } else {
                state.lang = '\(lang)';
                localStorage.setItem('talkie_lang', '\(lang)');
                save();
                applyStaticTranslations();
            }
            applyOledMode(\(AppState.shared.oledMode));
            """
            if vm.hasELConsent {
                js += "\nlocalStorage.setItem('talkie_el_consent', '1');"
            } else {
                js += "\nlocalStorage.removeItem('talkie_el_consent');"
            }
            if vm.hasAiConsent {
                js += "\nlocalStorage.setItem('talkie_ai_consent', '1');"
            } else {
                js += "\nlocalStorage.removeItem('talkie_ai_consent');"
            }
            js += "\nstate.llmEnabled = \(vm.llmEnabled);"
            // Sync quick phrases
            if let jsonData = try? JSONEncoder().encode(vm.quickPhrases),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                let escaped = Self.escapeForJavaScript(jsonStr)
                js += "\nwindow._updateQuickPhrases && window._updateQuickPhrases('\(escaped)');"
            }
            runJavaScript(js)
        }

        /// Chaîne injectée dans une apostrophe simple côté JS.
        private static func escapeForJavaScript(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let pct = AppState.shared.textSizePercent
            let oled = AppState.shared.oledMode
            let callActive = CallModeManager.shared.isPhoneCallActive
            let js = """
            window._setTextSize && window._setTextSize(\(pct));
            window._setOledMode && window._setOledMode(\(oled));
            window._callModeChanged && window._callModeChanged(\(callActive));
            """
            Task { @MainActor in
                do {
                    _ = try await webView.evaluateJavaScript(js)
                } catch {
                    // Best-effort text scale / oled mode
                }
            }
        }

        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: "Talkie", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            if let vc = webView.window?.rootViewController {
                vc.present(alert, animated: true)
            } else { completionHandler() }
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            let cancelTitle = SettingsViewModel.shared.lang == "fr" ? "Annuler" : "Cancel"
            let alert = UIAlertController(title: "Talkie", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            if let vc = webView.window?.rootViewController {
                vc.present(alert, animated: true)
            } else { completionHandler(false) }
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            let cancelTitle = SettingsViewModel.shared.lang == "fr" ? "Annuler" : "Cancel"
            let alert = UIAlertController(title: "Talkie", message: prompt, preferredStyle: .alert)
            alert.addTextField { tf in tf.text = defaultText }
            alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })
            if let vc = webView.window?.rootViewController {
                vc.present(alert, animated: true)
            } else { completionHandler(nil) }
        }
    }
}
