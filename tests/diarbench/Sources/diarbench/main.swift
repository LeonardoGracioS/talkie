import Foundation
import AVFoundation
import FluidAudio

// Bench for VoiceIdentity (the app's file, symlinked). Usage: diarbench <dir> <table|one|long> [seed]
struct Turn { let spk: String; let start: Double; let end: Double }
let base = URL(fileURLWithPath: CommandLine.arguments[1])
let scenario = CommandLine.arguments[2]
let lines = try! String(contentsOf: base.appendingPathComponent("audio/turns.txt"), encoding: .utf8).split(separator: "\n")
func load(_ name: String) -> [Float] {
  let f = try! AVAudioFile(forReading: base.appendingPathComponent("audio/\(name)"))
  let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
  try! f.read(into: buf); return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}
var rng = SystemRandomNumberGenerator()
var clips: [(String, [Float])] = lines.map { l in let p = l.split(separator: "|"); return (String(p[1]), load("t\(p[0]).wav")) }
if scenario == "one" { clips = clips.filter { $0.0 == "Thomas" } }
let reps = scenario == "long" ? 6 : 3
var audio: [Float] = []; var turns: [Turn] = []
for _ in 0..<reps {
  for (k, (spk, clip)) in clips.enumerated() {
    var s = clip.map { $0 * Float.random(in: 0.25...0.9, using: &rng) }
    var r = s; for (d, a) in [(480, Float(0.35)), (1400, Float(0.2))] { for i in d..<s.count { r[i] += s[i-d] * a } }
    var label = spk
    // "long": every 7th phrase, the next speaker talks over the end (overlap / mixed phrase)
    if scenario == "long" && k % 7 == 3 {
      let other = clips[(k + 1) % clips.count].1.map { $0 * 0.5 }
      let off = r.count / 2
      r += [Float](repeating: 0, count: max(0, off + other.count - r.count))
      for i in 0..<other.count { r[off + i] += other[i] }
      label = "MIXED"
    }
    s = r
    let st = Double(audio.count) / 16000; audio += s
    turns.append(Turn(spk: label, start: st, end: Double(audio.count) / 16000))
    audio += [Float](repeating: 0, count: Int(Double.random(in: 0.4...1.2, using: &rng) * 16000))
  }
}
for i in 0..<audio.count { audio[i] += Float.random(in: -1...1, using: &rng) * Float(ProcessInfo.processInfo.environment["NOISE"].flatMap(Double.init) ?? 0.004) }

let models = try await DiarizerModels.downloadIfNeeded(to: base.appendingPathComponent("models"))
let dia = DiarizerManager(config: .default); dia.initialize(models: models)

var vi = VoiceIdentity()
var assigned: [String: String] = [:]      // turnId -> voice
var merges = 0
func wire(_ v: VoiceIdentity) {
  v.onPromote = { id, earlier in for t in earlier where (assigned[t] ?? "").isEmpty { assigned[t] = id } }
  v.onMerge = { from, into in merges += 1; for (k, x) in assigned where x == from { assigned[k] = into } }
}
wire(vi)
let restartAt = turns.count / 2
for (i, tr) in turns.enumerated() {
  if scenario == "long" && i == restartAt {           // app relaunch: persist + restore
    let data = vi.encoded()!; vi = VoiceIdentity(); vi.restore(from: data); wire(vi)
  }
  let a = Int(tr.start * 16000), b = min(audio.count, Int(tr.end * 16000))
  let seg = Array(audio[a..<b].suffix(8 * 16000))
  guard let e = try? dia.extractSpeakerEmbedding(from: seg) else { continue }
  let id = vi.assign(embedding: e, duration: Float(tr.end - tr.start), turnId: "t\(i)", now: tr.end)
  vi.mergeConverged()
  assigned["t\(i)"] = id.isEmpty ? (assigned["t\(i)"] ?? "") : id
}
// metrics
var conf: [String: [String: Int]] = [:]
for (i, tr) in turns.enumerated() { conf[String(tr.spk.prefix(7)), default: [:]][assigned["t\(i)"].map { $0.isEmpty ? "-" : $0 } ?? "-", default: 0] += 1 }
var major: [String: String] = [:]
for (spk, c) in conf where spk != "MIXED" { major[spk] = c.filter { $0.key != "-" }.max { $0.value < $1.value }?.key ?? "-" }
let distinct = Set(major.values).count == major.count
var ok = 0, total = 0
for (i, tr) in turns.enumerated() where tr.spk != "MIXED" { total += 1; if assigned["t\(i)"] == major[String(tr.spk.prefix(7))] { ok += 1 } }
print("scenario=\(scenario) turns=\(turns.count) true_speakers=\(Set(turns.map(\.spk)).subtracting(["MIXED"]).count) → voices=\(vi.voices.count) \(vi.voices.map(\.id)) merges=\(merges) distinct_majorities=\(distinct) correct=\(ok)/\(total)")
print("   ", conf.sorted { $0.key < $1.key }.map { "\($0.key)→\($0.value.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))" }.joined(separator: "   "))
