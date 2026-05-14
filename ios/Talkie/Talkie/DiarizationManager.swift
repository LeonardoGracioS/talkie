import Foundation
import AVFoundation
import FluidAudio
import os

private let diarLogger = Logger(subsystem: "com.leonardogracios.talkie", category: "Diarization")

/// Streams microphone audio through FluidAudio's diarizer to detect *which* of
/// several speakers is currently talking. Reports a stable speakerId every time
/// the speaker changes; the web layer maps those ids to user-friendly names.
///
/// Why not Apple's stack: as of iOS 26 the public `SpeechAnalyzer` / Speech
/// framework does not expose any speaker label (verified via the WWDC25 session
/// and the iOS 26 docs). FluidAudio bundles pyannote-segmentation + wespeaker
/// CoreML models that run on the Neural Engine on-device — no network, no
/// account, no Apple Intelligence eligibility check.
@MainActor
final class DiarizationManager {

    static let shared = DiarizationManager()

    /// Emitted on the main thread when the active speaker changes.
    /// The String is a stable per-conversation id assigned by FluidAudio
    /// (e.g. "1", "2"); the second value is the segment start time in seconds
    /// relative to the start of this listening session.
    var onSpeakerChange: ((String, Float) -> Void)?

    /// Set to `false` to disable diarization without unloading the models.
    var enabled: Bool = true

    private var diarizer: DiarizerManager?
    private var isLoaded = false
    private var isLoading = false
    private var isRunning = false

    /// AVAudioEngine instance dedicated to the diarization input tap. We do
    /// **not** reuse the main playback engine — input/output share the same
    /// AVAudioSession but each engine manages its own taps independently, and
    /// keeping them separate avoids tearing down ElevenLabs playback when we
    /// stop listening.
    private var inputEngine: AVAudioEngine?

    /// PCM 16 kHz mono Float32 buffer fed by the input tap.
    private var pcmRing: [Float] = []
    /// Cap the ring so memory doesn't grow unbounded over a long session.
    /// 16 kHz × 30 s ≈ 1.9 MB.
    private let maxRingSamples = 16_000 * 30
    /// Sliding window we process per tick.
    private let windowSamples = 16_000 * 8
    /// Minimum audio required before the first run.
    private let minSamplesToRun = 16_000 * 3

    private var processingTask: Task<Void, Never>?
    private var lastSeenSpeakerId: String?

    private init() {}

    // MARK: - Lifecycle

    func prepare() {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        Task.detached { [weak self] in
            do {
                diarLogger.info("Downloading / loading diarizer models…")
                let models = try await DiarizerModels.downloadIfNeeded()
                let dia = DiarizerManager()
                dia.initialize(models: models)
                await MainActor.run { [weak self] in
                    self?.diarizer = dia
                    self?.isLoaded = true
                    self?.isLoading = false
                    diarLogger.info("Diarizer ready.")
                }
            } catch {
                diarLogger.error("Diarizer load failed: \(String(describing: error), privacy: .public)")
                await MainActor.run { [weak self] in
                    self?.isLoading = false
                }
            }
        }
    }

    func start() {
        guard enabled, isLoaded, !isRunning, diarizer != nil else {
            if !isLoaded { prepare() }
            return
        }
        pcmRing.removeAll(keepingCapacity: true)
        lastSeenSpeakerId = nil
        installInputTap()
        startProcessingLoop()
        isRunning = true
        diarLogger.info("Diarization session started.")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        processingTask?.cancel()
        processingTask = nil
        removeInputTap()
        pcmRing.removeAll(keepingCapacity: false)
        lastSeenSpeakerId = nil
        diarLogger.info("Diarization session stopped.")
    }

    var status: String {
        if isLoading { return "loading" }
        if isLoaded { return isRunning ? "running" : "idle" }
        return "unloaded"
    }

    // MARK: - Input tap

    private func installInputTap() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // Target: 16 kHz mono Float32 — required by the FluidAudio pyannote model.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { return }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            diarLogger.error("AVAudioConverter init failed (in=\(inputFormat) out=\(targetFormat))")
            return
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Convert to 16 kHz mono Float32. We allocate a generous output buffer:
            // input/output sample rate ratio + a safety margin.
            let outCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate + 64
            )
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

            var convError: NSError?
            var bufferConsumed = false
            converter.convert(to: outBuf, error: &convError) { _, status in
                if bufferConsumed {
                    status.pointee = .endOfStream
                    return nil
                }
                bufferConsumed = true
                status.pointee = .haveData
                return buffer
            }
            if let err = convError {
                diarLogger.error("Audio convert error: \(err.localizedDescription)")
                return
            }
            guard let chanData = outBuf.floatChannelData?[0], outBuf.frameLength > 0 else { return }
            let frames = Int(outBuf.frameLength)
            let samples = Array(UnsafeBufferPointer(start: chanData, count: frames))
            // Hop to the main actor before mutating the ring buffer.
            Task { @MainActor [weak self] in
                self?.appendToRing(samples)
            }
        }

        engine.prepare()
        do {
            try engine.start()
            inputEngine = engine
        } catch {
            diarLogger.error("Diarization engine.start() failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
        }
    }

    private func removeInputTap() {
        inputEngine?.inputNode.removeTap(onBus: 0)
        inputEngine?.stop()
        inputEngine = nil
    }

    private func appendToRing(_ samples: [Float]) {
        pcmRing.append(contentsOf: samples)
        if pcmRing.count > maxRingSamples {
            pcmRing.removeFirst(pcmRing.count - maxRingSamples)
        }
    }

    // MARK: - Processing loop

    private func startProcessingLoop() {
        processingTask = Task { @MainActor [weak self] in
            while let self, self.isRunning {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 s tick
                if Task.isCancelled { break }
                await self.processWindow()
            }
        }
    }

    private func processWindow() async {
        guard isRunning, let diarizer else { return }
        let total = pcmRing.count
        guard total >= minSamplesToRun else { return }

        let take = min(windowSamples, total)
        let window = Array(pcmRing.suffix(take))

        do {
            let result = try await diarizer.performCompleteDiarization(
                window,
                sampleRate: 16_000,
                atTime: 0
            )
            // Only fire onSpeakerChange when the *latest* segment's speaker differs
            // from the last one we reported — avoids spamming the web layer.
            guard let last = result.segments.last else { return }
            if last.speakerId != lastSeenSpeakerId {
                lastSeenSpeakerId = last.speakerId
                onSpeakerChange?(last.speakerId, last.startTimeSeconds)
                diarLogger.info("Speaker change → id=\(last.speakerId, privacy: .public)")
            }
        } catch {
            diarLogger.error("Diarization run failed: \(String(describing: error), privacy: .public)")
        }
    }
}
