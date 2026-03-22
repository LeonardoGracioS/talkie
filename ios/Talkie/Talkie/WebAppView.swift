import SwiftUI
import WebKit
import AVFoundation
import FoundationModels
import Security
import SafariServices
import UIKit

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

    func makeUIView(context: Context) -> WKWebView {
        // CRITICAL: Configure audio session for simultaneous playback + recording
        // Without this, iOS switches to "playback" mode after TTS and blocks the mic
        Self.configureAudioSession()

        // Clear cached HTML/JS so fresh bundle files always load
        WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
            modifiedSince: Date.distantPast
        ) { }

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // WKWebView suit le schéma système (`prefers-color-scheme`), pas `preferredColorScheme` SwiftUI.
        // On injecte le thème effectif pour que le CSS corresponde (ex. mode sombre dans Talkie + système clair).
        let theme = context.environment.colorScheme == .dark ? "dark" : "light"
        let themeScript = WKUserScript(
            source: """
            document.documentElement.setAttribute('data-app-theme', '\(theme)');
            (function(){var m=document.querySelector('meta[name="theme-color"]');if(m)m.content='\(theme == "dark" ? "#1C1C1E" : "#F5F6FA")';})();
            """,
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

        if let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            // Grant read access to the entire bundle to avoid sandbox extension errors
            webView.loadFileURL(htmlURL, allowingReadAccessTo: Bundle.main.bundleURL)
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let theme = colorScheme == .dark ? "dark" : "light"
        let bgColor: UIColor = colorScheme == .dark ? .secondarySystemGroupedBackground : .systemGroupedBackground
        uiView.backgroundColor = bgColor
        uiView.scrollView.backgroundColor = bgColor
        let meta = theme == "dark" ? "#1C1C1E" : "#F5F6FA"
        let js = """
        document.documentElement.setAttribute('data-app-theme', '\(theme)');
        (function(){var m=document.querySelector('meta[name="theme-color"]');if(m)m.content='\(meta)';})();
        """
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

    // MARK: - Audio Session Management (with state tracking to avoid cascading interruptions)

    /// Whether the audio session is currently active (avoids redundant activate/deactivate cycles
    /// that cause "AudioSession::beginInterruption but session is already interrupted!" spam).
    private static var sessionActive = false

    static func deactivateAudioSession() {
        guard sessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        } catch {
            // Session may already be inactive
            sessionActive = false
        }
    }

    static func reassertPlayAndRecordSession() {
        let session = AVAudioSession.sharedInstance()
        // Only deactivate if currently active — avoids triggering extra interruption notifications
        if sessionActive {
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                sessionActive = false
            } catch {
                sessionActive = false
            }
        }
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
            )
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
            sessionActive = true
        } catch {
            print("[Audio] activate failed: \(error)")
        }
    }

    /// Initial audio session setup — category only, no activate (avoids empty buffer issues at startup).
    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
            )
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        } catch {
            print("[Audio] init category failed: \(error)")
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
        AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
        weak var webView: WKWebView?
        private var audioSessionObservers: [NSObjectProtocol] = []

        /// ElevenLabs MP3 played natively so WebKit never owns playback — fixes mic + SpeechRecognition after TTS.
        private var nativeAudioPlayer: AVAudioPlayer?
        private var nativePlaybackId: String?
        private var nativeProgressTimer: Timer?
        private var nativeSynthesizer = AVSpeechSynthesizer()
        private var nativeSpeechCallbackId: String?

        override init() {
            super.init()
            nativeSynthesizer.delegate = self
        }

        /// Préfère l'API `async` de WKWebView (évite l'avertissement « asynchronous alternative »).
        @MainActor
        private func runJavaScript(_ script: String) {
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
            nativeAudioPlayer?.stop()
            let nc = NotificationCenter.default
            for o in audioSessionObservers { nc.removeObserver(o) }
        }

        private func handlePlayTTSFromData(message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let playbackId = body["playbackId"] as? String,
                  let base64 = body["base64"] as? String,
                  let data = Data(base64Encoded: base64),
                  !data.isEmpty else {
                print("[NativeTTS] invalid or empty payload")
                return
            }
            stopNativeTTSPlayback(notifyJS: false)
            WebAppView.reassertPlayAndRecordSession()
            do {
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                nativePlaybackId = playbackId
                nativeAudioPlayer = player
                guard player.prepareToPlay() else {
                    print("[NativeTTS] prepareToPlay failed")
                    failNativeTTS(playbackId: playbackId, code: "prepare_failed")
                    return
                }
                player.play()
                startNativeProgressTimer(playbackId: playbackId)
            } catch {
                print("[NativeTTS] AVAudioPlayer error: \(error)")
                failNativeTTS(playbackId: playbackId, code: "decode_failed")
            }
        }

        private func failNativeTTS(playbackId: String, code: String) {
            nativeProgressTimer?.invalidate()
            nativeProgressTimer = nil
            nativeAudioPlayer = nil
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
            nativeAudioPlayer?.stop()
            nativeAudioPlayer = nil
            let id = nativePlaybackId
            nativePlaybackId = nil

            if nativeSynthesizer.isSpeaking {
                nativeSynthesizer.stopSpeaking(at: .immediate)
            }

            WebAppView.reassertPlayAndRecordSession()
            if notifyJS, let id = id {
                let js = "window._nativeTTSPlayback && window._nativeTTSPlayback('\(id)', 'stopped');"
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
            print("[NativeTTS] decode error: \(error?.localizedDescription ?? "?")")
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

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            WebAppView.deactivateAudioSession()
            guard let id = nativeSpeechCallbackId else { return }
            nativeSpeechCallbackId = nil
            let js = "window._nativeSpeechCallback && window._nativeSpeechCallback('\(id)', null);"
            DispatchQueue.main.async { [weak self] in
                self?.runJavaScript(js)
            }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            WebAppView.deactivateAudioSession()
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
                      let type = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.ended.rawValue else { return }
                // Don't reassert while actively playing — the player manages the session
                guard self?.nativeAudioPlayer == nil, self?.nativeSynthesizer.isSpeaking != true else { return }
                WebAppView.reassertPlayAndRecordSession()
            })
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "resetAudioSession" {
                WebAppView.reassertPlayAndRecordSession()
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
                    // `LanguageModelSession` n'a pas d'init throwing dans le SDK actuel — la dispo réelle se joue à `respond`.
                    let available = true
                    let js = "window._llmAvailabilityCallback(\(available));"
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

                WebAppView.reassertPlayAndRecordSession()
                nativeSpeechCallbackId = requestId
                // Sanitize text to prevent AVSpeechSynthesizer from attempting SSML parsing.
                // Characters like <, >, & cause "Could not parse SSML" errors.
                let sanitized = text
                    .replacingOccurrences(of: "&", with: " et ")
                    .replacingOccurrences(of: "<", with: "")
                    .replacingOccurrences(of: ">", with: "")
                let utterance = AVSpeechUtterance(string: sanitized)
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate

                AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if status == .authorized,
                           let personalVoice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.voiceTraits.contains(.isPersonalVoice) }) {
                            utterance.voice = personalVoice
                        } else {
                            utterance.voice = AVSpeechSynthesisVoice(language: "fr-FR")
                        }
                        self.nativeSynthesizer.speak(utterance)
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
                    DispatchQueue.main.async {
                        MicState.shared.isListening = listening
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

            guard message.name == "llmRequest",
                  let body = message.body as? [String: Any],
                  let requestId = body["requestId"] as? String,
                  let prompt = body["prompt"] as? String,
                  let systemPrompt = body["systemPrompt"] as? String else {
                return
            }

            Task {
                await generateWithAppleLLM(requestId: requestId, systemPrompt: systemPrompt, prompt: prompt)
            }
        }

        @MainActor
        func generateWithAppleLLM(requestId: String, systemPrompt: String, prompt: String) async {
            guard let webView else { return }
            let safetyPrefix = "Tu ne dois JAMAIS générer de contenu violent, haineux, sexuel, discriminatoire ou illégal. Si on te le demande, refuse poliment.\n\n"
            /// - Extraction mémoire : courte consigne, préfixée par la règle de sécurité.
            /// - Suggestions : chaîne complète construite dans le Web (mémoire + historique) ; le cœur doit rester le prompt Talkie fixe.
            let instructions: String
            if systemPrompt.hasPrefix("Tu es un assistant qui extrait") {
                instructions = safetyPrefix + systemPrompt
            } else {
                guard systemPrompt.contains(TalkieSystemPrompt.integrityMarker) else {
                    let js = "window._llmCallback('\(requestId)', null, 'Configuration assistant invalide');"
                    do {
                        _ = try await webView.evaluateJavaScript(js)
                    } catch {
                        print("[LLM] JS erreur (config invalide): \(error)")
                    }
                    return
                }
                instructions = systemPrompt
            }
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: prompt)
                let text = response.content
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "")
                let js = "window._llmCallback('\(requestId)', '\(text)', null);"
                do {
                    _ = try await webView.evaluateJavaScript(js)
                } catch {
                    print("[LLM] Échec envoi résultat au Web: \(error)")
                }
            } catch {
                let errMsg = error.localizedDescription
                    .replacingOccurrences(of: "'", with: "\\'")
                let js = "window._llmCallback('\(requestId)', null, '\(errMsg)');"
                do {
                    _ = try await webView.evaluateJavaScript(js)
                } catch {
                    print("[LLM] Échec envoi erreur au Web: \(error)")
                }
            }
        }

        // MARK: - Native Settings Bridge

        @MainActor
        private func openNativeSettings() {
            guard let webView = self.webView else { return }
            let js = """
            JSON.stringify({
                memory: state.memory || '',
                useApplePersonalVoice: state.useApplePersonalVoice,
                useElevenLabs: state.useElevenLabs,
                elApiKey: state.elApiKey || '',
                voiceId: state.voiceId || '',
                hasELConsent: !!localStorage.getItem('talkie_el_consent')
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
                    vm.useApplePersonalVoice = dict["useApplePersonalVoice"] as? Bool ?? false
                    vm.useElevenLabs = dict["useElevenLabs"] as? Bool ?? false
                    vm.elApiKey = dict["elApiKey"] as? String ?? ""
                    if vm.elApiKey.isEmpty, let k = KeychainHelper.load(key: "elApiKey"), !k.isEmpty {
                        vm.elApiKey = k
                    }
                    vm.voiceId = dict["voiceId"] as? String ?? ""
                    vm.hasELConsent = dict["hasELConsent"] as? Bool ?? false
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
                localStorage.removeItem('talkie_v1');
                localStorage.removeItem('talkie_onboarded');
                ['echo_v5','echo_v4','echo_v3','echo_v2','echo_v1','echo_onboarded'].forEach(k => localStorage.removeItem(k));
                location.reload();
                """
                self?.runJavaScript(js)
            }

            vm.onOpenVoiceCloning = { [weak self] in
                self?.syncSettingsToJS()
                let js = "loadSettings(); showView('settings'); $('devSection').classList.add('visible');"
                self?.runJavaScript(js)
            }

            vm.onTextSizeChanged = { [weak self] pct in
                let js = "window._setTextSize && window._setTextSize(\(pct));"
                self?.runJavaScript(js)
            }

            AppState.shared.showSettings = true
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
            let voiceId = Self.escapeForJavaScript(vm.voiceId)
            let elKey = Self.escapeForJavaScript(vm.elApiKey)

            var js = """
            state.elApiKey = '\(elKey)';
            state.memory = '\(memory)';
            state.useApplePersonalVoice = \(vm.useApplePersonalVoice);
            state.useElevenLabs = \(vm.useElevenLabs);
            state.voiceId = '\(voiceId)';
            save();
            """
            if vm.hasELConsent {
                js += "\nlocalStorage.setItem('talkie_el_consent', '1');"
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
            let js = "window._setTextSize && window._setTextSize(\(pct));"
            Task { @MainActor in
                do {
                    _ = try await webView.evaluateJavaScript(js)
                } catch {
                    // Best-effort text scale
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
            let alert = UIAlertController(title: "Talkie", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Annuler", style: .cancel) { _ in completionHandler(false) })
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
            let alert = UIAlertController(title: "Talkie", message: prompt, preferredStyle: .alert)
            alert.addTextField { tf in tf.text = defaultText }
            alert.addAction(UIAlertAction(title: "Annuler", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })
            if let vc = webView.window?.rootViewController {
                vc.present(alert, animated: true)
            } else { completionHandler(nil) }
        }
    }
}
