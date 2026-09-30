# diarbench — voice identity regression bench

Replays a synthetic 3-voice conversation through the app's own `VoiceIdentity.swift`
(symlinked) with FluidAudio per-phrase embeddings, and checks people are neither merged
nor multiplied.

```bash
cd tests/diarbench
./make_audio.sh
swift run -c release diarbench "$PWD" table    # 3 voices   → expect voices=3, correct=54/54
swift run -c release diarbench "$PWD" one      # 1 voice    → expect voices=1
NOISE=0.05 swift run -c release diarbench "$PWD" long   # overlaps + app restart mid-way → voices=3
```

Models download on first run into `models/` (or copy `speaker-diarization` from a simulator).
Baseline before the fix (windowed-segment identity): 0/54 turns attributed correctly.
