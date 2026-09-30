import Foundation

/// "Who is speaking" from one speaker embedding per transcribed phrase.
///
/// Why per phrase: FluidAudio's windowed diarization computes one embedding per
/// *local slot* of a 10 s chunk, and its segmentation often puts different people
/// in the same slot — every segment of the chunk then shares one embedding, so
/// identity built on it either merges everyone or mints ghosts from noise (the
/// "100 speakers" bug). An embedding of the phrase's own audio separates voices
/// cleanly (bench: same voice ≥ 0.55 cosine, different voices ≤ 0.39) and only
/// real, transcribed speech is ever considered — noise cannot create a person.
///
/// A new voice is never created from a single phrase: it waits as a candidate
/// until a second consistent phrase confirms it, then the earlier phrases are
/// attributed retroactively (`onPromote`).
///
/// Pure logic, no audio/UI — unit-tested by the diarization bench.
final class VoiceIdentity {
    struct Voice: Codable { var id: String; var emb: [Float]; var weight: Float }
    private struct Candidate { var emb: [Float]; var weight: Float; var turnIds: [String]; var dur: Float; var lastSeen: Double }

    private(set) var voices: [Voice] = []
    private var candidates: [Candidate] = []
    private(set) var nextId = 1

    /// A candidate became a voice: (voiceId, earlier turn ids now attributable to it).
    var onPromote: ((String, [String]) -> Void)?
    /// `from` was merged into `into` — the UI must remap.
    var onMerge: ((String, String) -> Void)?

    // Thresholds sit in the gap measured on the bench (0.39 … 0.55), leaning
    // toward "same person" because far-field phone audio lowers similarity.
    let matchSim: Float = 0.45       // phrase belongs to a known voice
    let updateSim: Float = 0.55      // confident enough to refine the voiceprint
    let candidateSim: Float = 0.50   // two unknown phrases from the same new person
    let mergeSim: Float = 0.68       // two voiceprints converged → same person
    let promoteTurns = 2
    let promoteDur: Float = 3.0      // seconds of speech before creating a person
    let maxVoices = 8
    let minDur: Float = 0.8          // shorter phrases give unreliable embeddings

    static func cos(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count); guard n > 0 else { return -2 }
        var d: Float = 0, x: Float = 0, y: Float = 0
        for i in 0..<n { d += a[i] * b[i]; x += a[i] * a[i]; y += b[i] * b[i] }
        let m = x.squareRoot() * y.squareRoot(); return m > 0 ? d / m : -2
    }

    private static func mix(_ a: [Float], _ wa: Float, _ b: [Float], _ wb: Float) -> [Float] {
        var r = a; let t = wa + wb
        for i in 0..<min(a.count, b.count) { r[i] = (a[i] * wa + b[i] * wb) / t }
        return r
    }

    /// Returns the voice id for this phrase, or "" while it's still unknown.
    func assign(embedding e: [Float], duration: Float, turnId: String, now: Double) -> String {
        guard e.count >= 16, duration >= minDur else { return "" }
        let w = min(duration, 8)
        var best = -1; var bs: Float = -2
        for (i, v) in voices.enumerated() { let s = Self.cos(e, v.emb); if s > bs { bs = s; best = i } }

        if best >= 0 && bs >= matchSim {
            if bs >= updateSim {
                voices[best].emb = Self.mix(voices[best].emb, voices[best].weight, e, w)
                voices[best].weight = min(voices[best].weight + w, 120)   // stays adaptable
            }
            return voices[best].id
        }

        // Unknown voice → candidate stage.
        candidates.removeAll { now - $0.lastSeen > 180 }
        var ci = -1; var cs: Float = -2
        for (i, c) in candidates.enumerated() { let s = Self.cos(e, c.emb); if s > cs { cs = s; ci = i } }
        if ci < 0 || cs < candidateSim {
            candidates.append(Candidate(emb: e, weight: w, turnIds: [turnId], dur: duration, lastSeen: now))
            if candidates.count > 6 { candidates.removeFirst() }
            ci = candidates.count - 1
        } else {
            var c = candidates[ci]
            c.emb = Self.mix(c.emb, c.weight, e, w); c.weight += w
            c.turnIds.append(turnId); c.dur += duration; c.lastSeen = now
            candidates[ci] = c
        }
        let c = candidates[ci]
        // The very first voice needs no confirmation (someone is obviously talking).
        let enough = voices.isEmpty ? c.dur >= 1.5 : (c.turnIds.count >= promoteTurns && c.dur >= promoteDur)
        guard enough else { return "" }
        candidates.remove(at: ci)
        if voices.count >= maxVoices {
            // Full: attach to the closest voice rather than inventing a 9th person.
            guard best >= 0 else { return "" }
            onPromote?(voices[best].id, Array(c.turnIds.dropLast()))
            return voices[best].id
        }
        let id = "S\(nextId)"; nextId += 1
        voices.append(Voice(id: id, emb: c.emb, weight: c.weight))
        onPromote?(id, Array(c.turnIds.dropLast()))
        return id
    }

    /// Merge voices whose prints converged (one person split early on).
    func mergeConverged() {
        var i = 0
        while i < voices.count {
            var j = i + 1
            while j < voices.count {
                if Self.cos(voices[i].emb, voices[j].emb) >= mergeSim {
                    let drop = voices.remove(at: j)
                    voices[i].emb = Self.mix(voices[i].emb, voices[i].weight, drop.emb, drop.weight)
                    voices[i].weight = min(voices[i].weight + drop.weight, 120)
                    onMerge?(drop.id, voices[i].id)
                } else { j += 1 }
            }
            i += 1
        }
    }

    func reset() { voices.removeAll(); candidates.removeAll(); nextId = 1 }

    // MARK: Persistence (voiceprints survive app restarts so "Marie" stays Marie)

    private struct Stored: Codable { var nextId: Int; var voices: [Voice] }

    func encoded() -> Data? { try? JSONEncoder().encode(Stored(nextId: nextId, voices: voices)) }

    func restore(from data: Data) {
        guard let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        voices = s.voices; nextId = max(s.nextId, voices.count + 1)
    }
}
