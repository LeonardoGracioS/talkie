import Foundation
import AVFoundation
import Speech
import FluidAudio
import CoreMedia
import os

private let sttLogger = Logger(subsystem: "com.leonardogracios.talkie", category: "SpeechCapture")

/// Debug: os.Logger lines don't show up via devicectl console, so mirror to stdout.
private func dbg(_ msg: String) {
    print("[STT] \(msg)")
    sttLogger.info("\(msg, privacy: .public)")
}

/// The on-device engine for the "table" / multi-speaker experience.
///
/// This is the fix for the core defect: previously the Web Speech recognizer and
/// FluidAudio ran on **two independent audio engines with no shared clock**, so
/// "who said what" could only be guessed via a global variable. Here a **single**
/// `AVAudioEngine` tap feeds both:
///
///   1. Apple's iOS 26 `SpeechTranscriber` (via `SpeechAnalyzer`) — high-quality
///      streaming STT whose results carry `CMTimeRange` timestamps, and which does
///      **not** kill/restart between phrases (so it doesn't drop words like Web
///      Speech did), and
///   2. FluidAudio diarization — reusing the model already loaded by
///      `DiarizationManager` (no second engine, no second mic grab).
///
/// Because both consume the same buffers in order, their timelines coincide. Each
/// finalized transcript phrase `[start, end]` is then **fused** with the speaker
/// segments overlapping that interval → the majority speaker. Speaker identity is
/// kept stable across diarization calls by matching embeddings to running
/// centroids (FluidAudio re-clusters per call and would otherwise permute labels).
@MainActor
final class SpeechCaptureManager {

    static let shared = SpeechCaptureManager()
    private init() {}

    // MARK: - Callbacks to the web layer (set by WebAppView.Coordinator)

    /// A finalized turn: (text, stableSpeakerId, startSec, endSec).
    /// `speakerId` is "" when diarization hasn't attributed the phrase yet.
    var onTurn: ((String, String, Double, Double) -> Void)?
    /// Live (volatile) partial transcript for on-screen feedback.
    var onInterim: ((String) -> Void)?
    /// "loading" | "downloading" | "running" | "unavailable" | "stopped" | "failed"
    var onStatus: ((String) -> Void)?

    private(set) var isRunning = false
    /// Far-field table mode changes diarization sensitivity slightly.
    var tableMode = false

    // MARK: - Audio + Speech

    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var diarTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?

    // Forced-finalization watchdog. Left alone, SpeechTranscriber can sit on many
    // seconds of audio before emitting a final — and suggestions only fire on
    // finals, which read as huge lag. When the volatile text stops changing for
    // `silenceBeforeFinalize`, we call analyzer.finalize() to flush the phrase NOW.
    private var lastVolatileText = ""
    private var lastVolatileAt = Date.distantPast
    private var finalizeInFlight = false
    private let silenceBeforeFinalize: TimeInterval = 1.1

    // MARK: - Diarization ring (16 kHz mono) on the shared session clock

    private var pcmRing: [Float] = []
    /// Rolling window we diarize each tick. Longer = more context for the
    /// clusterer = steadier speaker identity (less same-voice-split-in-two), while
    /// still covering the lag before SpeechTranscriber finalizes a phrase.
    private let ringSeconds = 16
    private var ringCapacity: Int { 16_000 * ringSeconds }
    /// Absolute count of 16 kHz samples fed since the session started. Defines the
    /// session clock: sample N happened at N / 16000 seconds — the same t=0 the
    /// analyzer uses for its first buffer.
    private var totalSamplesFed = 0
    /// Written on the audio thread; stamps each AnalyzerInput's `bufferStartTime`
    /// so the transcript timeline and the diarization ring share ONE clock by
    /// construction (no drift if a buffer conversion is ever dropped). Kept in
    /// lockstep with `totalSamplesFed` (both count appended 16 kHz frames).
    private nonisolated(unsafe) var stampSamples16k: Int64 = 0

    // MARK: - Speaker identity
    //
    // We assign speaker identity OURSELVES from the segment embeddings, rather than
    // trusting FluidAudio's per-window ids. Re-diarizing overlapping windows made
    // FluidAudio churn ids (same voice → several "speakers") in far-field. Here each
    // segment's 256-d embedding is matched to a small running set of confirmed
    // speakers with a deliberately *lenient* cosine-similarity threshold, so a
    // single voice stays one speaker. Threshold is looser in 1-to-1 (fragmentation
    // is the only failure mode) and a bit tighter at a table (must still separate).

    private struct Confirmed { var id: String; var emb: [Float]; var count: Int }
    private var confirmed: [Confirmed] = []
    private var nextSpk = 1
    /// Cosine similarity ≥ this ⇒ treat as the same, already-seen speaker.
    private var mergeSim: Float { tableMode ? 0.38 : 0.25 }

    /// Segments from the most recent diarization run, in absolute session seconds,
    /// carrying our consolidated speaker id.
    private struct Seg { let id: String; let start: Double; let end: Double }
    private var storedSegments: [Seg] = []
    private var lastSpeakerId: String = ""

    // MARK: - Lifecycle

    /// Reports availability to JS without starting capture.
    /// Emits: "available" | "needs_download" | "unavailable".
    func checkAvailability(lang: String) {
        Task { @MainActor in
            dbg("checkAvailability(\(lang)) isAvailable=\(SpeechTranscriber.isAvailable)")
            guard SpeechTranscriber.isAvailable else { onStatus?("unavailable"); return }
            // Don't prompt here — only rule out an explicit denial. The prompt (if
            // still needed) happens on start().
            let auth = SFSpeechRecognizer.authorizationStatus()
            dbg("speech auth status=\(auth.rawValue)")
            if auth == .denied || auth == .restricted { onStatus?("unavailable"); return }
            guard let loc = await Self.resolveLocale(lang) else {
                dbg("no supported locale for \(lang)")
                onStatus?("unavailable"); return
            }
            let installed = await SpeechTranscriber.installedLocales
            let isInstalled = installed.contains { $0.identifier == loc.identifier }
            dbg("locale=\(loc.identifier) installed=\(isInstalled) (installedLocales=\(installed.map(\.identifier)))")
            onStatus?(isInstalled ? "available" : "needs_download")
        }
    }

    func start(lang: String, tableMode: Bool) {
        guard !isRunning else { return }
        self.tableMode = tableMode
        isRunning = true
        resetSessionState()
        // Make sure the diarization model is (being) loaded — we reuse it.
        DiarizationManager.shared.prepare()
        onStatus?("loading")
        setupTask = Task { @MainActor [weak self] in
            await self?.setupAndRun(lang: lang)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        setupTask?.cancel(); setupTask = nil
        diarTask?.cancel(); diarTask = nil
        finalizeTask?.cancel(); finalizeTask = nil
        resultsTask?.cancel(); resultsTask = nil
        inputContinuation?.finish(); inputContinuation = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        // Finish the analyzer's stream so it releases the model gracefully.
        let a = analyzer
        analyzer = nil
        transcriber = nil
        Task { try? await a?.finalizeAndFinishThroughEndOfInput() }
        onStatus?("stopped")
        sttLogger.info("Native STT session stopped.")
    }

    func setTableMode(_ on: Bool) { tableMode = on }

    private func resetSessionState() {
        pcmRing.removeAll(keepingCapacity: true)
        totalSamplesFed = 0
        stampSamples16k = 0
        storedSegments.removeAll()
        // NOTE: `confirmed` / `nextSpk` intentionally persist across restarts. The
        // native session restarts after every spoken reply (auto-resume), and a
        // voice's identity must survive that — otherwise the same person would be
        // re-labelled each turn. They reset only when the app process restarts.
        lastSpeakerId = ""
        lastVolatileText = ""
        lastVolatileAt = .distantPast
        finalizeInFlight = false
    }

    /// Every 250 ms: if the volatile transcript has been stable for
    /// `silenceBeforeFinalize` (the speaker paused), force the analyzer to emit
    /// the final for that phrase instead of waiting for its own (slow) heuristic.
    private func startFinalizeWatchdog() {
        finalizeTask = Task { @MainActor [weak self] in
            while let self, self.isRunning {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { break }
                guard self.isRunning, !self.finalizeInFlight, !self.lastVolatileText.isEmpty,
                      Date().timeIntervalSince(self.lastVolatileAt) > self.silenceBeforeFinalize,
                      let analyzer = self.analyzer else { continue }
                self.finalizeInFlight = true
                dbg("silence \(self.silenceBeforeFinalize)s → forcing finalize()")
                do {
                    try await analyzer.finalize(through: nil)
                } catch {
                    dbg("finalize() failed: \(String(describing: error))")
                }
                self.finalizeInFlight = false
            }
        }
    }

    // MARK: - Setup

    private static func resolveLocale(_ lang: String) async -> Locale? {
        let id = lang.lowercased().hasPrefix("fr") ? "fr-FR" : "en-US"
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id))
    }

    private func setupAndRun(lang: String) async {
        dbg("setupAndRun(lang=\(lang)) begins")
        guard SpeechTranscriber.isAvailable else {
            dbg("SpeechTranscriber.isAvailable == false")
            fail("unavailable"); return
        }
        // The Speech framework still gates transcription behind its own
        // authorization (the same one webkitSpeechRecognition used before).
        let auth = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        dbg("requestAuthorization → \(auth.rawValue)")
        guard auth == .authorized else {
            sttLogger.error("Speech authorization not granted: \(auth.rawValue)")
            fail("unavailable"); return
        }
        guard let loc = await Self.resolveLocale(lang) else {
            dbg("resolveLocale failed for \(lang)")
            fail("unavailable"); return
        }
        dbg("locale resolved: \(loc.identifier)")

        let transcriber = SpeechTranscriber(
            locale: loc,
            transcriptionOptions: [],
            // .fastResults: lower-latency volatile updates — an AAC user is reading
            // along live, snappiness beats the last % of accuracy here.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        // Download the language model on first use if needed.
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier == loc.identifier }) {
            dbg("locale not installed → requesting asset install")
            onStatus?("downloading")
            do {
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await req.downloadAndInstall()
                    dbg("asset downloadAndInstall completed")
                } else {
                    dbg("assetInstallationRequest returned nil (nothing to install)")
                }
            } catch {
                dbg("asset install FAILED: \(String(describing: error))")
                fail("unavailable"); return
            }
        }
        guard isRunning else { dbg("aborted mid-setup (stopped)"); return }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            dbg("bestAvailableAudioFormat returned nil")
            fail("unavailable"); return
        }
        dbg("analyzer format: \(analyzerFormat)")

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        do {
            try await analyzer.start(inputSequence: stream)
            dbg("analyzer.start OK")
        } catch {
            dbg("analyzer.start FAILED: \(String(describing: error))")
            fail("failed"); return
        }
        guard isRunning else { dbg("aborted after analyzer.start (stopped)"); return }

        // Consume transcript results.
        resultsTask = Task { @MainActor [weak self] in
            guard let transcriber = self?.transcriber else { return }
            dbg("results loop started")
            do {
                for try await result in transcriber.results {
                    guard let self, self.isRunning else { break }
                    self.handleResult(result)
                }
                dbg("results loop finished normally")
            } catch {
                dbg("results stream ERROR: \(String(describing: error))")
            }
        }

        // Start the mic tap → feeds both the analyzer and the diarization ring.
        guard installTap(analyzerFormat: analyzerFormat) else {
            dbg("installTap FAILED")
            fail("failed"); return
        }
        dbg("tap installed, engine running")

        startDiarizationLoop()
        startFinalizeWatchdog()
        onStatus?("running")
        sttLogger.info("Native STT session running (locale=\(loc.identifier, privacy: .public), table=\(self.tableMode)).")
    }

    private func fail(_ status: String) {
        dbg("fail(\(status))")
        isRunning = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil
        inputContinuation?.finish(); inputContinuation = nil
        analyzer = nil; transcriber = nil
        onStatus?(status)
    }

    // MARK: - Mic tap

    /// Installs the single input tap. Converts each buffer twice: to the analyzer
    /// format (fed to SpeechTranscriber) and to 16 kHz mono (fed to the diarizer).
    private func installTap(analyzerFormat: AVAudioFormat) -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let format16k = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else { return false }
        guard let convToAnalyzer = AVAudioConverter(from: inputFormat, to: analyzerFormat),
              let convTo16k = AVAudioConverter(from: inputFormat, to: format16k) else {
            sttLogger.error("Converter init failed (in=\(inputFormat)).")
            return false
        }

        let continuation = self.inputContinuation
        dbg("input format: \(inputFormat)")

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Timestamp for THIS buffer on the shared 16 kHz clock (before advancing it).
            let startTime = CMTime(value: self.stampSamples16k, timescale: 16_000)
            // 1) → analyzer format → SpeechTranscriber, stamped so its result ranges
            //    live on exactly the same clock as the diarization segments below.
            if let outBuf = Self.convert(buffer, using: convToAnalyzer, to: analyzerFormat) {
                continuation?.yield(AnalyzerInput(buffer: outBuf, bufferStartTime: startTime))
            }
            // 2) → 16 kHz mono → diarization ring; advance the shared clock by the
            //    real appended frame count.
            if let outBuf = Self.convert(buffer, using: convTo16k, to: format16k),
               let chan = outBuf.floatChannelData?[0], outBuf.frameLength > 0 {
                let n = Int(outBuf.frameLength)
                let samples = Array(UnsafeBufferPointer(start: chan, count: n))
                self.stampSamples16k += Int64(n)
                Task { @MainActor [weak self] in self?.appendToRing(samples) }
            }
        }

        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
            return true
        } catch {
            sttLogger.error("engine.start failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return false
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter,
                                to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate + 64
        )
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            // `.noDataNow`, NOT `.endOfStream`: the converter is reused across tap
            // callbacks, and `.endOfStream` permanently poisons it — every later
            // convert() fails. (Bit us: Float32→Int16 + resampling asks for input
            // twice within one call, hitting the second branch.)
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        if err != nil || outBuf.frameLength == 0 { return nil }
        return outBuf
    }

    private func appendToRing(_ samples: [Float]) {
        pcmRing.append(contentsOf: samples)
        totalSamplesFed += samples.count
        if pcmRing.count > ringCapacity {
            pcmRing.removeFirst(pcmRing.count - ringCapacity)
        }
    }

    // MARK: - Diarization loop (reuses DiarizationManager's model)

    private func startDiarizationLoop() {
        diarTask = Task { @MainActor [weak self] in
            while let self, self.isRunning {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 s tick
                if Task.isCancelled { break }
                await self.runDiarizationOnce()
            }
        }
    }

    private func runDiarizationOnce() async {
        guard isRunning, DiarizationManager.shared.modelsReady else { return }
        let window = pcmRing
        guard window.count >= 16_000 * 2 else { return } // need ≥2 s
        // Absolute session time of the window's first sample.
        let windowStartSec = Double(totalSamplesFed - window.count) / 16_000.0
        let rawSegments = await DiarizationManager.shared.diarize(window, startTime: windowStartSec)
        if !rawSegments.isEmpty {
            dbg("diar: \(rawSegments.count) segment(s), windowStart=\(String(format: "%.1f", windowStartSec))s")
        }
        guard isRunning else { return }
        // Consolidate each segment to a stable speaker id via its embedding.
        storedSegments = rawSegments
            .map { Seg(id: consolidate($0.embedding), start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
    }

    /// Match an embedding to a confirmed speaker (lenient) or mint a new one.
    private func consolidate(_ embedding: [Float]) -> String {
        guard embedding.count >= 16 else { return lastSpeakerId.isEmpty ? "S1" : lastSpeakerId }
        var bestIdx = -1
        var bestSim: Float = -2
        for (i, c) in confirmed.enumerated() {
            let sim = Self.cosineSim(embedding, c.emb)
            if sim > bestSim { bestSim = sim; bestIdx = i }
        }
        if bestIdx >= 0 && bestSim >= mergeSim {
            // Running-average the matched speaker's embedding.
            var c = confirmed[bestIdx]
            let n = Float(c.count)
            let k = min(c.emb.count, embedding.count)
            for j in 0..<k { c.emb[j] = (c.emb[j] * n + embedding[j]) / (n + 1) }
            c.count += 1
            confirmed[bestIdx] = c
            dbg("spk match \(c.id) sim=\(String(format: "%.2f", bestSim)) (thr \(String(format: "%.2f", mergeSim)))")
            return c.id
        }
        let id = "S\(nextSpk)"
        nextSpk += 1
        confirmed.append(Confirmed(id: id, emb: embedding, count: 1))
        dbg("spk NEW \(id) bestSim=\(String(format: "%.2f", bestSim)) (thr \(String(format: "%.2f", mergeSim)))")
        return id
    }

    private static func cosineSim(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return -2 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<n { dot += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i] }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : -2
    }

    // MARK: - Transcript results + fusion

    private func handleResult(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        dbg("result final=\(result.isFinal) range=[\(result.range.start.seconds), \(result.range.end.seconds)] text=\"\(text.prefix(60))\"")
        guard !text.isEmpty else { return }
        if result.isFinal {
            lastVolatileText = ""
            lastVolatileAt = .distantPast
            let start = result.range.start.seconds
            let end = result.range.end.seconds
            let sStart = start.isFinite ? start : 0
            let sEnd = end.isFinite ? end : sStart
            let speaker = fuseSpeaker(start: sStart, end: sEnd)
            dbg("TURN speaker=\(speaker.isEmpty ? "?" : speaker) « \(text.prefix(40)) »")
            onTurn?(text, speaker, sStart, sEnd)
        } else {
            // Only count *changes* as activity — a repeated identical volatile
            // must not keep pushing the silence window forward.
            if text != lastVolatileText {
                lastVolatileText = text
                lastVolatileAt = Date()
            }
            onInterim?(text)
        }
    }

    /// Majority-overlap fusion: the speaker whose segments cover the most of the
    /// phrase's `[start, end]` wins. Falls back to the last known speaker when
    /// diarization hasn't caught up yet (keeps the thread coherent at a table).
    private func fuseSpeaker(start: Double, end: Double) -> String {
        guard end > start, !storedSegments.isEmpty else { return lastSpeakerId }
        var overlapById: [String: Double] = [:]
        for seg in storedSegments {
            let ov = min(end, seg.end) - max(start, seg.start)
            if ov > 0 { overlapById[seg.id, default: 0] += ov }
        }
        if let best = overlapById.max(by: { $0.value < $1.value })?.key {
            lastSpeakerId = best
            return best
        }
        return lastSpeakerId
    }
}
