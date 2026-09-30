# Talkie

Assistive communication app for people with ALS (Charcot disease) and speech impairments. It listens to the
conversation, suggests replies, and speaks the chosen one — in the user's own (cloned or Personal) voice.

## iOS App (`ios/Talkie/`)

SwiftUI shell + `WKWebView` UI (`Talkie/Resources/web/index.html`). Requires **iOS 26**.

- **Speech-to-text**: on-device `SpeechTranscriber` / `SpeechAnalyzer` (`SpeechCaptureManager.swift`), with
  FluidAudio speaker diarization on the same audio clock ("who said what"). Web Speech is only a fallback.
- **Reply suggestions**: Apple Foundation Models on device (`TalkieLLMModels.swift`); optional Claude (user API key).
- **Text-to-speech**: AVSpeechSynthesizer / Apple Personal Voice, or ElevenLabs (cloned voice). During phone calls,
  speech is injected into the call via iOS 18.2+ microphone injection (`CallModeManager.swift`).
- Settings are native (`SettingsView.swift`); API keys live in the Keychain.

### Build

```bash
cd ios/Talkie
xcodegen generate    # project.yml is the source of truth
open Talkie.xcodeproj
```

### Tests

Pure web helpers (content filter, suggestion parsing, TTS chunking) live in `Resources/web/pure.js`:

```bash
node --test tests/web/pure.test.js
```

## License

MIT
