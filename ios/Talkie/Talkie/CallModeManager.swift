import AVFoundation
import CallKit
import os

private let callLogger = Logger(subsystem: "com.leonardogracios.talkie", category: "CallMode")

/// Observes system phone / FaceTime audio calls.
/// IMPORTANT: never reconfigure AVAudioSession when a call starts — iOS owns audio
/// during calls and fighting it crashes or kills the app. Only touch audio right
/// before TTS playback (`prepareForCallModeTTS`).
final class CallModeManager: NSObject, CXCallObserverDelegate {
    static let shared = CallModeManager()

    private let callObserver = CXCallObserver()
    private(set) var isPhoneCallActive = false

    /// `(active)` — true when a cellular / FaceTime audio call is in progress.
    var onCallModeChanged: ((Bool) -> Void)?

    override init() {
        super.init()
        callObserver.setDelegate(self, queue: .main)
        refreshCallState()
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        refreshCallState()
    }

    private func refreshCallState() {
        let active = callObserver.calls.contains { !$0.hasEnded }
        guard active != isPhoneCallActive else { return }
        isPhoneCallActive = active
        callLogger.info("Call mode \(active ? "active" : "inactive", privacy: .public)")

        if active {
            requestMicrophoneInjectionPermissionIfNeeded()
            Task { @MainActor in
                DiarizationManager.shared.stop()
            }
        } else {
            WebAppView.resetAudioSessionConfiguration()
            WebAppView.reassertPlayAndRecordSession(force: true)
        }

        onCallModeChanged?(active)
    }

    /// iOS 18.2+ telephony audio injection (Settings ▸ Accessibility ▸ Audio & Visual ▸
    /// "Allow Apps to Add Audio in Calls"). Requesting this is what makes the app appear in
    /// that per-app list and grants it the priority to feed the call uplink. Without a
    /// granted permission, the synthesizer's audio is rejected with `InsufficientPriority`
    /// and the interlocutor hears nothing — which is exactly the bug we hit.
    ///
    /// Requires `NSMicrophoneInjectionUsageDescription` in Info.plist; the system terminates
    /// the app if it requests permission without that key.
    func requestMicrophoneInjectionPermissionIfNeeded() {
        let status = AVAudioApplication.shared.microphoneInjectionPermission
        callLogger.info("Mic-injection permission: \(String(describing: status), privacy: .public)")
        guard status == .undetermined else { return }
        AVAudioApplication.requestMicrophoneInjectionPermission { result in
            callLogger.info("Mic-injection permission result: \(String(describing: result), privacy: .public)")
        }
    }

    /// Arm iOS 18.2+ microphone injection right before TTS so the audio the app plays is added
    /// to the call's microphone uplink (what the other party hears).
    ///
    /// Use `.playback` (NOT `.playAndRecord`): during a call the app only needs to *play* — the
    /// system adds that playback to the mic uplink. `.playAndRecord` contends for the mic, which
    /// the call owns, so `setActive` fails with `InsufficientPriority` and aborts the audio.
    static func prepareForCallModeTTS() {
        guard shared.isPhoneCallActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            try session.setPreferredMicrophoneInjectionMode(.spokenAudio)
            callLogger.info("Call-mode injection armed (.playback + .spokenAudio)")
        } catch {
            callLogger.warning("Call-mode injection prep failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
