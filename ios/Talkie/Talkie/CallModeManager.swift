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

    /// Light audio prep before TTS during a call.
    /// Actual call routing is handled by AVSpeechSynthesizer.mixToTelephonyUplink.
    static func prepareForCallModeTTS() {
        guard shared.isPhoneCallActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // Do not fight the telephony session — only ensure we can mix if needed.
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]
            )
            try session.setActive(true)
            callLogger.info("Call-mode TTS audio prepared (telephony uplink via mixToTelephonyUplink)")
        } catch {
            callLogger.warning("Call-mode TTS prep failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
