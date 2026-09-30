import Foundation
import AVFoundation
import Speech
import FluidAudio
import CoreMedia
import os

private let sttLogger = Logger(subsystem: "com.leonardogracios.talkie", category: "SpeechCapture")

/// Debug only — never in Release/TestFlight builds (transcripts are private).
private func dbg(_ msg: String) {
    #if DEBUG
    print("[STT] \(msg)")
    sttLogger.info("\(msg, privacy: .public)")
    #endif
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
    private init() {
        UserDefaults.standard.removeObject(forKey: "talkie_voice_centroids_v1")   // built by the old, broken identity
        if let d = UserDefaults.standard.data(forKey: Self.voicesKey) { identity.restore(from: d) }
        identity.onPromote = { [weak self] id, turnIds in
            for t in turnIds { self?.onTurnSpeakerUpdate?(t, id) }
            self?.saveVoices()
        }
        identity.onMerge = { [weak self] from, into in self?.onSpeakerMerge?(from, into) }
    }

    // MARK: - Callbacks to the web layer (set by WebAppView.Coordinator)

    /// A finalized turn: (text, stableSpeakerId, startSec, endSec, turnId).
    /// `speakerId` is "" when diarization hasn't attributed the phrase yet; when it
    /// resolves later, `onTurnSpeakerUpdate(turnId, speakerId)` fires (P1.3).
    var onTurn: ((String, String, Double, Double, String) -> Void)?
    /// Retroactive speaker attribution for a previously-emitted turn.
    var onTurnSpeakerUpdate: ((String, String) -> Void)?
    /// Two voice ids turned out to be the same person: (from, into).
    var onSpeakerMerge: ((String, String) -> Void)?
    /// Live (volatile) partial transcript for on-screen feedback.
    var onInterim: ((String) -> Void)?
    /// "loading" | "downloading" | "running" | "unavailable" | "stopped" | "failed"
    var onStatus: ((String) -> Void)?

    private(set) var isRunning = false
    /// Far-field table mode changes diarization sensitivity slightly.
    var tableMode = false
    /// Paused during TTS playback: engine stays alive but we stop feeding the
    /// analyzer/diarizer (so Talkie's own voice from the speaker is never
    /// transcribed) — far cheaper than tearing the whole session down (P1.1).
    /// Read on the audio thread; a stale read costs at most one extra buffer.
    private nonisolated(unsafe) var suspended = false

    // MARK: - Audio + Speech

    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?

    // Forced-finalization watchdog. Left alone, SpeechTranscriber can sit on many
    // seconds of audio before emitting a final — and suggestions only fire on
    // finals, which read as huge lag. When the volatile text stops changing for
    // `silenceBeforeFinalize`, we call analyzer.finalize() to flush the phrase NOW.
    private var lastVolatileText = ""
    private var lastVolatileAt = Date.distantPast
    private var finalizeInFlight = false
    /// "Patience" before force-finalizing a paused phrase. Configurable (P1.4):
    /// slow/hesitant speakers need more, quick exchanges want less. Default 1.4 s.
    private var silenceBeforeFinalize: TimeInterval = 1.4

    // MARK: - Audio ring (16 kHz mono) on the shared session clock
    // Holds the recent audio so each finalized phrase's own samples can be embedded.

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

    // MARK: - Speaker identity (one voiceprint per phrase — see VoiceIdentity)

    private let identity = VoiceIdentity()
    private static let voicesKey = "talkie_voiceprints_v2"
    private var lastSpeakerId: String = ""
    private var turnCounter = 0
    /// Phrases are embedded one after another so turns reach the UI in order.
    private var turnChain: Task<Void, Never>?

    /// Retained teardown of the previous analyzer, so a fast stop→start (toggle
    /// table, resume after TTS) doesn't run two analyzers at once (P1.6).
    private var teardownTask: Task<Void, Never>?

    /// Bumped on every start()/stop(). A setup task that resumes after an `await`
    /// with a stale generation abandons itself — otherwise stop→start during the
    /// model download ran two analyzers + two taps (T8).
    private var sessionGen = 0
    private func alive(_ gen: Int) -> Bool { isRunning && gen == sessionGen && !Task.isCancelled }

    /// Last start() parameters, reused to restart after an interruption / route change (T5).
    private var lastLang = "fr"
    private var lastPatience: Double = 1.4
    /// Names (relatives, speakers, profile) biasing the recognizer toward proper nouns (T23).
    private var vocabulary: [String] = []
    private var audioObservers: [NSObjectProtocol] = []
    private var restartWork: DispatchWorkItem?

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

    func start(lang: String, tableMode: Bool, patience: Double = 1.4, vocabulary: [String] = []) {
        guard !isRunning else { return }
        self.tableMode = tableMode
        self.silenceBeforeFinalize = max(0.6, min(3.0, patience))
        self.lastLang = lang
        self.lastPatience = patience
        self.vocabulary = vocabulary
        isRunning = true
        sessionGen += 1
        let gen = sessionGen
        resetSessionState()
        // Make sure the diarization model is (being) loaded — we reuse it.
        DiarizationManager.shared.prepare()
        onStatus?("loading")
        setupTask = Task { @MainActor [weak self] in
            // Ensure the previous session's analyzer is fully released first (P1.6).
            await self?.teardownTask?.value
            await self?.setupAndRun(lang: lang, gen: gen)
        }
    }

    // MARK: - Pause / resume (during TTS) — P1.1
    //
    // Keep the analyzer + engine + loaded model alive; just stop feeding audio.
    // Tearing the whole session down after every spoken reply cost ~1 s of
    // "reloading" and churned memory.

    func pause() {
        guard isRunning, !suspended else { return }
        suspended = true
        // Flush the phrase the interlocutor was finishing: its final arrives while
        // suspended and is delivered (handleResult only drops volatiles) — T6.
        if !lastVolatileText.isEmpty, let a = analyzer {
            Task { try? await a.finalize(through: nil) }
        }
        lastVolatileText = ""; lastVolatileAt = .distantPast
        saveVoices()
        dbg("paused (TTS)")
    }

    func resume() {
        guard isRunning, suspended else { return }
        suspended = false
        // Drop whatever leaked in around the TTS so it's never transcribed/diarized.
        pcmRing.removeAll(keepingCapacity: true)
        lastVolatileText = ""; lastVolatileAt = .distantPast
        dbg("resumed")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sessionGen += 1
        removeAudioObservers()
        saveVoices()
        setupTask?.cancel(); setupTask = nil
        finalizeTask?.cancel(); finalizeTask = nil
        resultsTask?.cancel(); resultsTask = nil
        inputContinuation?.finish(); inputContinuation = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        suspended = false
        // Retain the teardown so a following start() awaits it — never two
        // analyzers finalizing at once (P1.6). cancelAndFinishNow() is immediate.
        let a = analyzer
        analyzer = nil
        transcriber = nil
        teardownTask = Task { await a?.cancelAndFinishNow() }
        onStatus?("stopped")
        sttLogger.info("Native STT session stopped.")
    }

    func setTableMode(_ on: Bool) { tableMode = on }

    // MARK: - Interruption / route-change recovery (T5)
    //
    // Siri, an alarm, AirPods connecting… stop the AVAudioEngine behind our back.
    // Without this the UI kept showing "listening" over a dead mic.

    private func addAudioObservers() {
        removeAudioObservers()
        let nc = NotificationCenter.default
        audioObservers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRestartIfEngineStopped(reason: "config change") }
        })
        audioObservers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            guard type == .ended else { return }
            MainActor.assumeIsolated { self?.scheduleRestartIfEngineStopped(reason: "interruption ended") }
        })
    }

    private func removeAudioObservers() {
        restartWork?.cancel(); restartWork = nil
        audioObservers.forEach { NotificationCenter.default.removeObserver($0) }
        audioObservers.removeAll()
    }

    private func scheduleRestartIfEngineStopped(reason: String) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, !CallModeManager.shared.isPhoneCallActive else { return }
                guard self.engine?.isRunning == false else { return }
                sttLogger.info("Audio engine stopped (\(reason, privacy: .public)) — restarting capture.")
                let wasSuspended = self.suspended
                let (lang, table, patience, vocab) = (self.lastLang, self.tableMode, self.lastPatience, self.vocabulary)
                self.stop()
                WebAppView.configureAudioSessionForCurrentMode()
                self.start(lang: lang, tableMode: table, patience: patience, vocabulary: vocab)
                if wasSuspended { self.suspended = true }
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Persistent voice identity

    private func saveVoices() {
        if let d = identity.encoded() { UserDefaults.standard.set(d, forKey: Self.voicesKey) }
    }

    /// Forget every voiceprint ("Effacer les interlocuteurs", reset).
    func resetSpeakers() {
        identity.reset()
        lastSpeakerId = ""
        UserDefaults.standard.removeObject(forKey: Self.voicesKey)
    }

    private func resetSessionState() {
        pcmRing.removeAll(keepingCapacity: true)
        totalSamplesFed = 0
        stampSamples16k = 0
        // Voiceprints (`identity`) persist across sessions and launches on purpose.
        lastSpeakerId = ""
        lastVolatileText = ""
        lastVolatileAt = .distantPast
        finalizeInFlight = false
        suspended = false
    }

    /// Every 250 ms: if the volatile transcript has been stable for
    /// `silenceBeforeFinalize` (the speaker paused), force the analyzer to emit
    /// the final for that phrase instead of waiting for its own (slow) heuristic.
    private func startFinalizeWatchdog() {
        finalizeTask = Task { @MainActor [weak self] in
            while let self, self.isRunning {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { break }
                guard self.isRunning, !self.suspended, !self.finalizeInFlight, !self.lastVolatileText.isEmpty,
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

    private func setupAndRun(lang: String, gen: Int) async {
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
        guard alive(gen) else { return }
        guard auth == .authorized else {
            sttLogger.error("Speech authorization not granted: \(auth.rawValue)")
            fail("unavailable"); return
        }
        guard let loc = await Self.resolveLocale(lang) else {
            guard alive(gen) else { return }
            dbg("resolveLocale failed for \(lang)")
            fail("unavailable"); return
        }
        guard alive(gen) else { return }
        dbg("locale resolved: \(loc.identifier)")

        let transcriber = SpeechTranscriber(
            locale: loc,
            transcriptionOptions: [],
            // .fastResults: lower-latency volatile updates — an AAC user is reading
            // along live, snappiness beats the last % of accuracy here.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )

        // Download the language model on first use if needed.
        let installed = await SpeechTranscriber.installedLocales
        guard alive(gen) else { return }
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
                guard alive(gen) else { return }
                dbg("asset install FAILED: \(String(describing: error))")
                fail("unavailable"); return
            }
        }
        guard alive(gen) else { dbg("aborted mid-setup (stale/stopped)"); return }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            guard alive(gen) else { return }
            dbg("bestAvailableAudioFormat returned nil")
            fail("unavailable"); return
        }
        guard alive(gen) else { return }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.transcriber = transcriber
        self.analyzer = analyzer
        dbg("analyzer format: \(analyzerFormat)")

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        // Bias recognition toward names the user cares about (T23). Best-effort.
        if !vocabulary.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = Array(vocabulary.prefix(100))
            try? await analyzer.setContext(ctx)
        }

        do {
            try await analyzer.start(inputSequence: stream)
            dbg("analyzer.start OK")
        } catch {
            guard alive(gen) else { return }
            dbg("analyzer.start FAILED: \(String(describing: error))")
            fail("failed"); return
        }
        guard alive(gen) else {
            dbg("aborted after analyzer.start (stale/stopped)")
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            return
        }

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
                // Tell the web layer instead of silently going deaf (T5).
                if let self, self.isRunning, self.sessionGen == gen { self.fail("failed") }
            }
        }

        // Start the mic tap → feeds both the analyzer and the diarization ring.
        guard installTap(analyzerFormat: analyzerFormat) else {
            dbg("installTap FAILED")
            fail("failed"); return
        }
        dbg("tap installed, engine running")

        addAudioObservers()
        startFinalizeWatchdog()
        onStatus?("running")
        sttLogger.info("Native STT session running (locale=\(loc.identifier, privacy: .public), table=\(self.tableMode)).")
    }

    private func fail(_ status: String) {
        dbg("fail(\(status))")
        isRunning = false
        sessionGen += 1
        removeAudioObservers()
        finalizeTask?.cancel(); finalizeTask = nil
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

        dbg("input format: \(inputFormat)")

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat,
                         block: Self.makeTapBlock(owner: self, continuation: inputContinuation,
                                                  convToAnalyzer: convToAnalyzer, analyzerFormat: analyzerFormat,
                                                  convTo16k: convTo16k, format16k: format16k))

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

    /// Built in a nonisolated context on purpose: a closure formed inside this
    /// @MainActor class would inherit main-actor isolation, and Swift 6's runtime
    /// isolation checks crash when the audio thread calls it.
    private nonisolated static func makeTapBlock(
        owner: SpeechCaptureManager, continuation: AsyncStream<AnalyzerInput>.Continuation?,
        convToAnalyzer: AVAudioConverter, analyzerFormat: AVAudioFormat,
        convTo16k: AVAudioConverter, format16k: AVAudioFormat
    ) -> AVAudioNodeTapBlock {
        return { [weak owner] buffer, _ in
            guard let owner, !owner.suspended else { return }   // paused during TTS (P1.1)
            // Timestamp for THIS buffer on the shared 16 kHz clock (before advancing it).
            let startTime = CMTime(value: owner.stampSamples16k, timescale: 16_000)
            // 1) → analyzer format → SpeechTranscriber, stamped so its result ranges
            //    live on exactly the same clock as the diarization segments below.
            if let outBuf = convert(buffer, using: convToAnalyzer, to: analyzerFormat) {
                continuation?.yield(AnalyzerInput(buffer: outBuf, bufferStartTime: startTime))
            }
            // 2) → 16 kHz mono → diarization ring; advance the shared clock by the
            //    real appended frame count.
            if let outBuf = convert(buffer, using: convTo16k, to: format16k),
               let chan = outBuf.floatChannelData?[0], outBuf.frameLength > 0 {
                let n = Int(outBuf.frameLength)
                let samples = Array(UnsafeBufferPointer(start: chan, count: n))
                owner.stampSamples16k += Int64(n)
                Task { @MainActor [weak owner] in owner?.appendToRing(samples) }
            }
        }
    }

    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter,
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
        // Trim in ~1 s batches so removeFirst (O(n)) runs about once a second, not
        // on every tap buffer (which was shifting ~256k floats ~15×/s) — P1.2.
        if pcmRing.count > ringCapacity + 16_000 {
            pcmRing.removeFirst(pcmRing.count - ringCapacity)
        }
    }

    // MARK: - Transcript results → speaker

    private func handleResult(_ result: SpeechTranscriber.Result) {
        // No audio is fed while suspended, so a FINAL arriving now comes from speech
        // captured BEFORE the pause — keep it (T6). Only live volatiles are hidden.
        if suspended && !result.isFinal { return }
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if result.isFinal {
            lastVolatileText = ""
            lastVolatileAt = .distantPast
            let start = result.range.start.seconds
            let end = result.range.end.seconds
            let sStart = start.isFinite ? start : 0
            let sEnd = end.isFinite ? end : sStart
            turnCounter += 1
            let turnId = "t\(turnCounter)"
            let samples = phraseSamples(start: sStart, end: sEnd)
            let previous = turnChain
            turnChain = Task { @MainActor [weak self] in
                await previous?.value
                guard let self else { return }
                var speaker = ""
                if let samples, let emb = await DiarizationManager.shared.embed(samples) {
                    speaker = self.identity.assign(embedding: emb, duration: Float(sEnd - sStart), turnId: turnId,
                                                   now: Date().timeIntervalSince1970)
                    self.identity.mergeConverged()
                }
                if !speaker.isEmpty { self.lastSpeakerId = speaker }
                dbg("TURN \(turnId) speaker=\(speaker.isEmpty ? "?" : speaker)")
                // "" = voice not confirmed yet: the UI keeps the current speaker, and
                // onPromote fixes this turn retroactively if it becomes a new person.
                self.onTurn?(text, speaker, sStart, sEnd, turnId)
            }
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

    /// The phrase's own audio from the ring (last 8 s of it at most), or nil if
    /// too short / already scrolled out of the ring.
    private func phraseSamples(start: Double, end: Double) -> [Float]? {
        let ringStart = totalSamplesFed - pcmRing.count            // absolute index of pcmRing[0]
        let a = max(Int(start * 16_000), ringStart, Int(end * 16_000) - 8 * 16_000)
        let b = min(Int(end * 16_000), totalSamplesFed)
        guard b - a >= Int(identity.minDur * 16_000) else { return nil }
        return Array(pcmRing[(a - ringStart)..<(b - ringStart)])
    }
}
