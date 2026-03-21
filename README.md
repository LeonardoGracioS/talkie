# Talkie

Assistive communication app for people with ALS (Charcot disease) and speech impairments. Combines voice cloning, speech recognition, and AI-powered response suggestions to help users communicate naturally.

## Components

### iOS App (`ios/Talkie/`)

Native iOS app wrapping a web-based interface with:

- **Voice cloning** via ElevenLabs API — clone any voice from short audio samples
- **Speech-to-text** using Web Speech API for real-time transcription
- **AI response suggestions** — context-aware quick replies powered by Apple Intelligence (on-device)
- **Text-to-speech** with the cloned voice for natural-sounding output
- **Conversation management** — multiple threads with history

Built with SwiftUI + WKWebView. Requires iOS 17+. Uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) for project generation.

#### Setup

```bash
cd ios/Talkie
xcodegen generate    # generates Talkie.xcodeproj
open Talkie.xcodeproj
```

Configure API keys in the app's Settings screen:
- **ElevenLabs** — for voice cloning and TTS

### Voice Cloner (`app.py`)

Standalone Gradio web app for local voice cloning, supporting multiple TTS engines:

- **Qwen3-TTS 0.6B** — multilingual (10 languages including French)
- **NeuTTS Air 0.5B** — EN/FR/ES/DE
- **Sopro 135M** — English only, ultra-fast

Runs fully on-device (MPS on Apple Silicon, CPU fallback).

#### Setup

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python app.py
```

Open `http://localhost:7860` — record a voice sample, then generate speech.

## License

MIT
