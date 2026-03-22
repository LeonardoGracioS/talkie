import SwiftUI
import WebKit
import AVFoundation
import FoundationModels
import Security
import SafariServices

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

    func makeUIView(context: Context) -> WKWebView {
        // CRITICAL: Configure audio session for simultaneous playback + recording
        // Without this, iOS switches to "playback" mode after TTS and blocks the mic
        configureAudioSession()

        // Clear cached HTML/JS so fresh bundle files always load
        WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
            modifiedSince: Date.distantPast
        ) { }

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

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
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// WebKit leaves the session in playback mode after HTML5 audio (e.g. ElevenLabs MP3).
    /// Full deactivate → category → activate is required before SpeechRecognition can start again.
    ///
    /// **Important:** Do *not* use `.voiceChat` here — its built-in voice processing / echo cancellation
    /// can leave the capture path gated after speaker playback, so Web Speech API gets no audio.
    static func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[Audio] deactivate: \(error)")
        }
    }

    static func reassertPlayAndRecordSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[Audio] deactivate: \(error)")
        }
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
            )
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
            print("[Audio] Session ready: playAndRecord (default)")
        } catch {
            print("[Audio] activate failed: \(error)")
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
            )
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
                  let data = Data(base64Encoded: base64) else {
                print("[NativeTTS] invalid payload")
                return
            }
            print("[NativeTTS] start playbackId=\(playbackId) bytes=\(data.count)")
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
                self?.webView?.evaluateJavaScript(js) { err, _ in
                    if let err = err { print("[NativeTTS] JS fail callback error: \(err)") }
                }
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
                    self?.webView?.evaluateJavaScript(js) { err, _ in
                        if let err = err { print("[NativeTTS] JS stop notify error: \(err)") }
                    }
                }
            }
        }

        private func startNativeProgressTimer(playbackId: String) {
            nativeProgressTimer?.invalidate()
            let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                guard let self = self, let p = self.nativeAudioPlayer else { return }
                let cur = p.currentTime
                let dur = max(p.duration, 0.001)
                let js = "window._nativeTTSProgress && window._nativeTTSProgress('\(playbackId)', \(cur), \(dur))"
                self.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
            RunLoop.main.add(t, forMode: .common)
            nativeProgressTimer = t
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            print("[NativeTTS] finished success=\(flag)")
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
                self?.webView?.evaluateJavaScript(js) { err, _ in
                    if let err = err { print("[NativeTTS] JS done callback error: \(err)") }
                }
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
                    self?.webView?.evaluateJavaScript(js) { err, _ in
                        if let err = err { print("[NativeTTS] JS decode callback error: \(err)") }
                    }
                }
            }
        }

        /// WebKit / HTML5 audio can interrupt the shared session; re-sync when the interruption ends.

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            WebAppView.deactivateAudioSession()
            guard let id = nativeSpeechCallbackId else { return }
            nativeSpeechCallbackId = nil
            let js = "window._nativeSpeechCallback && window._nativeSpeechCallback('\(id)', null);"
            DispatchQueue.main.async { [weak self] in
                self?.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
        
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            WebAppView.deactivateAudioSession()
            guard let id = nativeSpeechCallbackId else { return }
            nativeSpeechCallbackId = nil
            let js = "window._nativeSpeechCallback && window._nativeSpeechCallback('\(id)', 'cancelled');"
            DispatchQueue.main.async { [weak self] in
                self?.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
        func startObservingAudioSessionRecovery() {
            guard audioSessionObservers.isEmpty else { return }
            let nc = NotificationCenter.default
            audioSessionObservers.append(nc.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { note in
                guard let info = note.userInfo,
                      let type = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.ended.rawValue else { return }
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
                    var available = true
                    do {
                        let session = LanguageModelSession()
                        let _ = try await session.respond(to: "test")
                    } catch let error as LanguageModelSession.GenerationError {
                        // GenerationError means the model exists but rejected the prompt — still available
                        available = true
                        _ = error
                    } catch {
                        available = false
                    }
                    let js = "window._llmAvailabilityCallback(\(available));"
                    self?.webView?.evaluateJavaScript(js, completionHandler: nil)
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
                    self?.webView?.evaluateJavaScript(js, completionHandler: nil)
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
                    self?.webView?.evaluateJavaScript(js, completionHandler: nil)
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
                let utterance = AVSpeechUtterance(string: text)
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                
                AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                    DispatchQueue.main.async {
                        if status == .authorized, let personalVoice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.voiceTraits.contains(.isPersonalVoice) }) {
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
                        // Open mailto: links with the system mail handler
                        DispatchQueue.main.async {
                            UIApplication.shared.open(url)
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
                    self?.webView?.evaluateJavaScript(js, completionHandler: nil)
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
            do {
                let safetyPrefix = "Tu ne dois JAMAIS générer de contenu violent, haineux, sexuel, discriminatoire ou illégal. Si on te le demande, refuse poliment.\n\n"
                let session = LanguageModelSession(instructions: safetyPrefix + systemPrompt)
                let response = try await session.respond(to: prompt)
                let text = response.content
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "")
                let js = "window._llmCallback('\(requestId)', '\(text)', null);"
                try? await webView?.evaluateJavaScript(js)
            } catch {
                let errMsg = error.localizedDescription
                    .replacingOccurrences(of: "'", with: "\\'")
                let js = "window._llmCallback('\(requestId)', null, '\(errMsg)');"
                try? await webView?.evaluateJavaScript(js)
            }
        }

        // MARK: - Native Settings Bridge

        @MainActor
        private func openNativeSettings() {
            guard let webView = self.webView else { return }
            let js = """
            JSON.stringify({
                systemPrompt: state.systemPrompt,
                memory: state.memory || '',
                useApplePersonalVoice: state.useApplePersonalVoice,
                useElevenLabs: state.useElevenLabs,
                elApiKey: state.elApiKey || '',
                voiceId: state.voiceId || '',
                hasELConsent: !!localStorage.getItem('talkie_el_consent')
            })
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let jsonStr = result as? String,
                      let data = jsonStr.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    // Fallback: open settings anyway with defaults
                    self?.presentNativeSettings()
                    return
                }

                let vm = SettingsViewModel.shared
                vm.systemPrompt = dict["systemPrompt"] as? String ?? ""
                vm.memory = dict["memory"] as? String ?? ""
                vm.useApplePersonalVoice = dict["useApplePersonalVoice"] as? Bool ?? false
                vm.useElevenLabs = dict["useElevenLabs"] as? Bool ?? false
                vm.elApiKey = dict["elApiKey"] as? String ?? ""
                vm.voiceId = dict["voiceId"] as? String ?? ""
                vm.hasELConsent = dict["hasELConsent"] as? Bool ?? false

                self?.presentNativeSettings()
            }
        }

        @MainActor
        private func presentNativeSettings() {
            let vm = SettingsViewModel.shared

            vm.onDismiss = { [weak self] in
                self?.syncSettingsToJS()
                let restartJs = "if (userHasInteracted) startListening();"
                self?.webView?.evaluateJavaScript(restartJs, completionHandler: nil)
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
                self?.webView?.evaluateJavaScript(js, completionHandler: nil)
            }

            vm.onResetAll = { [weak self] in
                let js = """
                keychainDelete('elApiKey');
                localStorage.removeItem('talkie_v1');
                localStorage.removeItem('talkie_onboarded');
                ['echo_v5','echo_v4','echo_v3','echo_v2','echo_v1','echo_onboarded'].forEach(k => localStorage.removeItem(k));
                location.reload();
                """
                self?.webView?.evaluateJavaScript(js, completionHandler: nil)
            }

            vm.onOpenVoiceCloning = { [weak self] in
                self?.syncSettingsToJS()
                let js = "loadSettings(); showView('settings'); $('devSection').classList.add('visible');"
                self?.webView?.evaluateJavaScript(js, completionHandler: nil)
            }

            AppState.shared.showSettings = true
        }

        private func syncSettingsToJS() {
            let vm = SettingsViewModel.shared
            let prompt = vm.systemPrompt
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")
            let memory = vm.memory
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")
            let voiceId = vm.voiceId
                .replacingOccurrences(of: "'", with: "\\'")

            let js = """
            state.systemPrompt = '\(prompt)';
            state.memory = '\(memory)';
            state.useApplePersonalVoice = \(vm.useApplePersonalVoice);
            state.useElevenLabs = \(vm.useElevenLabs);
            state.voiceId = '\(voiceId)';
            save();
            """
            webView?.evaluateJavaScript(js, completionHandler: nil)

            // Save API key to keychain if present
            if !vm.elApiKey.isEmpty {
                let escapedKey = vm.elApiKey.replacingOccurrences(of: "'", with: "\\'")
                let keyJs = "keychainSave('elApiKey', '\(escapedKey)');"
                webView?.evaluateJavaScript(keyJs, completionHandler: nil)
            }

            // Sync ElevenLabs consent
            if vm.hasELConsent {
                let consentJs = "localStorage.setItem('talkie_el_consent', '1');"
                webView?.evaluateJavaScript(consentJs, completionHandler: nil)
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
