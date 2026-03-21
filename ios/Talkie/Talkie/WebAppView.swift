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

// Custom WKWebView that hides the iOS input accessory bar (˄ ˅ ✓)
class NoAccessoryWebView: WKWebView {
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        DispatchQueue.main.async { self.removeInputAccessory() }
    }

    func removeInputAccessory() {
        guard let contentView = scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContentView")
        }) else { return }
        let noAccessoryClass: AnyClass = NoAccessoryHelper.self
        let noAccessorySel = #selector(getter: NoAccessoryHelper.dummyAccessory)
        guard let noAccessoryMethod = class_getInstanceMethod(noAccessoryClass, noAccessorySel) else { return }
        let originalSel = NSSelectorFromString("inputAccessoryView")
        let contentClass: AnyClass = type(of: contentView)
        if let original = class_getInstanceMethod(contentClass, originalSel) {
            method_exchangeImplementations(original, noAccessoryMethod)
        } else {
            let imp = method_getImplementation(noAccessoryMethod)
            let typeEncoding = method_getTypeEncoding(noAccessoryMethod)
            class_addMethod(contentClass, originalSel, imp, typeEncoding)
        }
    }
}

class NoAccessoryHelper: NSObject {
    @objc var dummyAccessory: AnyObject? { return nil }
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

        let webView = NoAccessoryWebView(frame: .zero, configuration: config)
        webView.isOpaque = true
        webView.backgroundColor = UIColor(red: 242/255, green: 242/255, blue: 247/255, alpha: 1)
        webView.scrollView.backgroundColor = UIColor(red: 242/255, green: 242/255, blue: 247/255, alpha: 1)
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
            if #available(iOS 13.0, *) {
                try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            }
            try session.setActive(true)
            print("[Audio] Session ready: playAndRecord (default)")
        } catch {
            print("[Audio] activate failed: \(error)")
        }
    }

    private func configureAudioSession() {
        Self.reassertPlayAndRecordSession()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
        AVAudioPlayerDelegate {
        weak var webView: WKWebView?
        private var audioSessionObservers: [NSObjectProtocol] = []

        /// ElevenLabs MP3 played natively so WebKit never owns playback — fixes mic + SpeechRecognition after TTS.
        private var nativeAudioPlayer: AVAudioPlayer?
        private var nativePlaybackId: String?
        private var nativeProgressTimer: Timer?

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
                let available: Bool
                if #available(iOS 26.0, *) {
                    available = true
                } else {
                    available = false
                }
                let js = "window._llmAvailabilityCallback(\(available));"
                DispatchQueue.main.async { [weak self] in
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
            if message.name == "openURL" {
                if let urlString = message.body as? String,
                   let url = URL(string: urlString),
                   let vc = webView?.window?.rootViewController {
                    let safari = SFSafariViewController(url: url)
                    vc.present(safari, animated: true)
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
            if #available(iOS 26.0, *) {
                do {
                    let session = LanguageModelSession(instructions: systemPrompt)
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
            } else {
                let js = "window._llmCallback('\(requestId)', null, 'iOS 26+ requis pour Apple Intelligence');"
                try? await webView?.evaluateJavaScript(js)
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
