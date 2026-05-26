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
            Task { @MainActor in
                DiarizationManager.shared.stop()
            }
        } else {
            WebAppView.resetAudioSessionConfiguration()
            WebAppView.reassertPlayAndRecordSession(force: true)
        }

        onCallModeChanged?(active)
    }

    /// Configure audio only at TTS time — playback mixed with the call, routed to speaker.
    static func prepareForCallModeTTS() {
        guard shared.isPhoneCallActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.mixWithOthers, .duckOthers, .defaultToSpeaker]
            )
            try session.setActive(true)
            try session.overrideOutputAudioPort(.speaker)
            callLogger.info("Call-mode TTS audio prepared")
        } catch {
            // Non-fatal — TTS may still work via the system mixer.
            callLogger.warning("Call-mode TTS prep failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
