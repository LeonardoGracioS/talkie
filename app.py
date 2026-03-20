"""Voice Cloner — multi-model local voice cloning powered by Qwen3-TTS,
NeuTTS Air, and Sopro.

Records a short voice sample via the browser (or uses a pre-loaded file),
builds a reusable speaker prompt, then synthesises arbitrary text in the
cloned voice.  Runs fully on-device.
"""

import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

import gradio as gr
import librosa
import numpy as np
import soundfile as sf
import torch

# ── Paths ─────────────────────────────────────────────────────────

APP_DIR = Path(__file__).resolve().parent
DEFAULT_REF_AUDIO = APP_DIR / "reference.wav"
DEFAULT_REF_TEXT = ""

TARGET_SR = 24_000
MAX_NEW_TOKENS = 4096

# ── Model registry ────────────────────────────────────────────────

MODELS = {
    "Qwen3-TTS 0.6B  ·  Multilingual (10 langues dont FR)": "qwen",
    "NeuTTS Air 0.5B  ·  EN / FR / ES / DE": "neutts",
    "Sopro 135M  ·  English only — ultra-rapide": "sopro",
    "MioTTS 0.1B  ·  EN / JP — nécessite Ollama (non intégré)": "miotts",
}

_engine = None
_engine_name: str | None = None
_voice_prompt = None

LANGUAGES = [
    "Auto", "English", "French", "Chinese", "German",
    "Spanish", "Italian", "Japanese", "Korean",
    "Portuguese", "Russian",
]


# ── Audio helpers ─────────────────────────────────────────────────

def _prepare_audio(sr: int, data: np.ndarray) -> tuple[np.ndarray, int]:
    """Gradio mic → float32 mono 24 kHz."""
    if data.dtype == np.int16:
        data = data.astype(np.float32) / 32768.0
    elif data.dtype == np.int32:
        data = data.astype(np.float32) / 2_147_483_648.0
    elif data.dtype != np.float32:
        data = data.astype(np.float32)
    if data.ndim > 1:
        data = data.mean(axis=1)
    if sr != TARGET_SR:
        data = librosa.resample(data, orig_sr=sr, target_sr=TARGET_SR)
        sr = TARGET_SR
    return data, sr


def _audio_to_wav(audio) -> str:
    """Save Gradio audio tuple to a 24 kHz WAV and return the path."""
    sr, raw = audio
    data, sr = _prepare_audio(sr, raw)
    path = os.path.join(tempfile.gettempdir(), "vc_ref_24k.wav")
    sf.write(path, data, sr)
    return path


# ══════════════════════════════════════════════════════════════════
#  Engine wrappers — common interface:
#    load()  → None
#    register(wav_path, ref_text) → prompt object
#    generate(text, prompt, language) → (np.ndarray, int)
# ══════════════════════════════════════════════════════════════════

class QwenEngine:
    def __init__(self):
        self.model = None

    def load(self):
        from qwen_tts import Qwen3TTSModel
        cfg = {"device_map": "mps", "dtype": torch.bfloat16, "attn_implementation": "sdpa"}
        if not torch.backends.mps.is_available():
            cfg = {"device_map": "cpu", "dtype": torch.float32}
        self.model = Qwen3TTSModel.from_pretrained(
            "Qwen/Qwen3-TTS-12Hz-0.6B-Base", **cfg,
        )

    def register(self, wav_path: str, ref_text: str):
        return self.model.create_voice_clone_prompt(
            ref_audio=wav_path, ref_text=ref_text,
        )

    def generate(self, text: str, prompt, language: str):
        lang = language if language != "Auto" else "Auto"
        wavs, sr = self.model.generate_voice_clone(
            text=text, language=lang,
            voice_clone_prompt=prompt,
            max_new_tokens=MAX_NEW_TOKENS,
        )
        return wavs[0], sr


class NeuTTSEngine:
    def __init__(self):
        self.tts = None

    def load(self):
        import perth
        if perth.PerthImplicitWatermarker is None:
            perth.PerthImplicitWatermarker = perth.DummyWatermarker

        from neuttsair.neutts import NeuTTSAir
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.tts = NeuTTSAir(
            backbone_repo="neuphonic/neutts-air",
            backbone_device=device,
            codec_repo="neuphonic/neucodec",
            codec_device=device,
        )

    def register(self, wav_path: str, ref_text: str):
        ref_codes = self.tts.encode_reference(wav_path)
        return {"ref_codes": ref_codes, "ref_text": ref_text}

    def generate(self, text: str, prompt, language: str):
        wav = self.tts.infer(text, prompt["ref_codes"], prompt["ref_text"])
        return np.asarray(wav, dtype=np.float32), 24_000


class SoproEngine:
    def __init__(self):
        self.tts = None

    def load(self):
        from sopro import SoproTTS
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.tts = SoproTTS.from_pretrained(
            "samuel-vitorino/sopro", device=device,
        )

    def register(self, wav_path: str, ref_text: str):
        return self.tts.prepare_reference(ref_audio_path=wav_path)

    def generate(self, text: str, prompt, language: str):
        wav_tensor = self.tts.synthesize(text, ref=prompt)
        wav = wav_tensor.squeeze().cpu().numpy().astype(np.float32)
        return wav, 24_000


ENGINE_CLASSES = {
    "qwen": QwenEngine,
    "neutts": NeuTTSEngine,
    "sopro": SoproEngine,
}


# ── Engine management ─────────────────────────────────────────────

def _get_engine(model_key: str):
    global _engine, _engine_name, _voice_prompt
    if _engine_name == model_key and _engine is not None:
        return _engine

    if _engine is not None:
        del _engine
        torch.mps.empty_cache() if torch.backends.mps.is_available() else None
        import gc; gc.collect()

    cls = ENGINE_CLASSES.get(model_key)
    if cls is None:
        raise gr.Error("Ce modèle nécessite une configuration externe (Ollama).")

    print(f"[vc] Loading engine: {model_key} …")
    _engine = cls()
    _engine.load()
    _engine_name = model_key
    _voice_prompt = None
    print(f"[vc] Engine ready: {model_key}")
    return _engine


# ── Callbacks ─────────────────────────────────────────────────────

def register_voice(
    model_choice: str, audio, ref_text: str, progress=gr.Progress(track_tqdm=True),
) -> str:
    global _voice_prompt

    key = MODELS.get(model_choice)
    if key == "miotts":
        raise gr.Error(
            "MioTTS nécessite Ollama. Installe avec : "
            "brew install ollama && ollama pull hf.co/Aratako/MioTTS-GGUF:MioTTS-0.1B"
        )

    if audio is None:
        raise gr.Error("Enregistre ou uploade un sample vocal.")
    if not ref_text.strip():
        raise gr.Error("Tape le transcript de ton enregistrement.")

    wav_path = _audio_to_wav(audio)
    dur = librosa.get_duration(filename=wav_path)
    if dur < 2.0:
        raise gr.Error(f"Trop court ({dur:.1f}s). Vise 3–10 secondes.")

    progress(0.1, desc="Chargement du modèle …")
    engine = _get_engine(key)

    progress(0.6, desc="Enregistrement de la voix …")
    _voice_prompt = engine.register(wav_path, ref_text.strip())

    progress(1.0, desc="Terminé")
    return f"Voix enregistrée ({dur:.1f}s). Prêt à générer avec {model_choice.split('·')[0].strip()}."


def generate_speech(
    model_choice: str, text: str, language: str,
    progress=gr.Progress(track_tqdm=True),
):
    global _voice_prompt

    key = MODELS.get(model_choice)
    if key == "miotts":
        raise gr.Error("MioTTS nécessite Ollama (non intégré).")

    if _voice_prompt is None:
        raise gr.Error("Enregistre ta voix d'abord (Étape 1).")
    if not text.strip():
        raise gr.Error("Tape du texte à synthétiser.")

    if _engine_name != key:
        raise gr.Error("Le modèle a changé. Ré-enregistre ta voix d'abord.")

    progress(0.1, desc="Synthèse en cours …")
    t0 = time.time()
    wav, sr = _engine.generate(text.strip(), _voice_prompt, language)
    elapsed = time.time() - t0

    progress(0.9, desc="Finalisation …")
    dur = len(wav) / sr
    out = os.path.join(tempfile.gettempdir(), "vc_output.wav")
    sf.write(out, wav, sr)

    progress(1.0, desc="Terminé")
    return out, f"{dur:.1f}s générées en {elapsed:.0f}s"


# ── Tailscale ─────────────────────────────────────────────────────

def _detect_tailscale() -> str | None:
    for cli in ["tailscale",
                "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]:
        try:
            r = subprocess.run(
                [cli, "status", "--json"],
                capture_output=True, text=True, timeout=5,
            )
            if r.returncode == 0:
                return (
                    json.loads(r.stdout)
                    .get("Self", {})
                    .get("DNSName", "")
                    .rstrip(".")
                ) or None
        except (FileNotFoundError, Exception):
            continue
    return None


# ── Theme & CSS ───────────────────────────────────────────────────

THEME = gr.themes.Base(
    primary_hue=gr.themes.colors.amber,
    secondary_hue=gr.themes.colors.stone,
    neutral_hue=gr.themes.colors.stone,
    font=[gr.themes.GoogleFont("Outfit"), "system-ui", "sans-serif"],
    font_mono=[gr.themes.GoogleFont("IBM Plex Mono"), "ui-monospace", "monospace"],
)

CSS = """
@import url('https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,300;9..144,500;9..144,700&family=Outfit:wght@300;400;500;600;700&family=IBM+Plex+Mono:wght@400;500&display=swap');

.gradio-container {
    background: #050505 !important;
    max-width: 880px !important;
    margin: 0 auto !important;
    padding: 0 24px !important;
}
.main, .contain { background: #050505 !important; }
footer { display: none !important; }

/* ── header ───────────────────────────── */
.vc-header {
    text-align: center;
    padding: 44px 16px 28px;
    position: relative;
    overflow: hidden;
}
.vc-header::before {
    content: '';
    position: absolute;
    top: -60%; left: 50%; transform: translateX(-50%);
    width: 500px; height: 500px;
    background: radial-gradient(circle, rgba(217,119,6,0.08) 0%, transparent 70%);
    pointer-events: none;
}
.vc-header h1 {
    font-family: 'Fraunces', serif !important;
    font-size: 2.6rem; font-weight: 700;
    color: #fff; margin: 0 0 6px; letter-spacing: -0.03em;
    position: relative;
}
.vc-header h1 span { color: #d97706; }
.vc-header p {
    color: #6b6560; font-size: 0.95rem; line-height: 1.6;
    max-width: 460px; margin: 0 auto; position: relative;
}
.vc-wave {
    display: flex; align-items: center; justify-content: center;
    gap: 3px; height: 24px; margin: 22px auto 0;
}
.vc-wave i {
    display: block; width: 3px; border-radius: 2px;
    background: #d97706; animation: vc-p 1.4s ease-in-out infinite;
}
.vc-wave i:nth-child(1){height:6px;animation-delay:0s}
.vc-wave i:nth-child(2){height:14px;animation-delay:.08s}
.vc-wave i:nth-child(3){height:22px;animation-delay:.16s}
.vc-wave i:nth-child(4){height:24px;animation-delay:.24s}
.vc-wave i:nth-child(5){height:16px;animation-delay:.32s}
.vc-wave i:nth-child(6){height:22px;animation-delay:.4s}
.vc-wave i:nth-child(7){height:10px;animation-delay:.48s}
.vc-wave i:nth-child(8){height:18px;animation-delay:.56s}
.vc-wave i:nth-child(9){height:12px;animation-delay:.64s}
.vc-wave i:nth-child(10){height:6px;animation-delay:.72s}
@keyframes vc-p {
    0%,100%{transform:scaleY(.35);opacity:.45}
    50%{transform:scaleY(1);opacity:1}
}

/* ── model selector ───────────────────── */
.vc-model-bar {
    max-width: 640px;
    margin: 0 auto 20px;
}

/* ── panels ───────────────────────────── */
.vc-step-tag {
    font-family: 'IBM Plex Mono', monospace !important;
    font-size: 0.7rem; font-weight: 500;
    text-transform: uppercase; letter-spacing: 0.18em;
    color: #d97706; margin-bottom: 4px;
}
.vc-step-title {
    font-family: 'Fraunces', serif !important;
    font-size: 1.2rem; font-weight: 500;
    color: #f5f0eb; margin-bottom: 16px;
}
.vc-panel {
    background: #0a0a0b !important;
    border: 1px solid #1a1a1c !important;
    border-radius: 16px !important;
    padding: 24px 20px !important;
}

/* ── controls ─────────────────────────── */
.gradio-container textarea,
.gradio-container input[type="text"] {
    background: #0f0f10 !important; border: 1px solid #1f1f22 !important;
    color: #e8e4df !important; border-radius: 10px !important;
    font-family: 'Outfit', system-ui !important;
    transition: border-color .2s, box-shadow .2s !important;
}
.gradio-container textarea:focus,
.gradio-container input[type="text"]:focus {
    border-color: #d97706 !important;
    box-shadow: 0 0 0 3px rgba(217,119,6,.10) !important;
    outline: none !important;
}
.gradio-container button.primary {
    background: #d97706 !important; color: #000 !important;
    font-weight: 600 !important; border: none !important;
    border-radius: 10px !important; padding: 10px 24px !important;
    transition: background .2s, box-shadow .25s, transform .15s !important;
}
.gradio-container button.primary:hover {
    background: #f59e0b !important;
    box-shadow: 0 0 20px rgba(217,119,6,.25) !important;
    transform: translateY(-1px) !important;
}
.gradio-container button.primary:active { transform: translateY(0) !important; }
.vc-status textarea {
    font-family: 'IBM Plex Mono', monospace !important;
    font-size: .82rem !important; color: #22c55e !important;
    background: transparent !important; border: none !important;
}
.gradio-container label span {
    color: #8a857f !important; font-size: .85rem !important;
}

/* ── footer ───────────────────────────── */
.vc-footer {
    text-align: center; padding: 24px 0 8px;
    font-family: 'IBM Plex Mono', monospace !important;
    font-size: .72rem; color: #333; letter-spacing: .06em;
}
"""

HEADER_HTML = """
<div class="vc-header">
    <h1>Voice <span>Cloner</span></h1>
    <p>Clone n'importe quelle voix localement. Choisis ton modèle,
       enregistre un sample, puis tape ton texte.</p>
    <div class="vc-wave">
        <i></i><i></i><i></i><i></i><i></i>
        <i></i><i></i><i></i><i></i><i></i>
    </div>
</div>
"""


# ── UI ────────────────────────────────────────────────────────────

default_audio_value = str(DEFAULT_REF_AUDIO) if DEFAULT_REF_AUDIO.exists() else None

with gr.Blocks(title="Voice Cloner") as app:

    gr.HTML(HEADER_HTML)

    with gr.Column(elem_classes=["vc-model-bar"]):
        model_dd = gr.Dropdown(
            choices=list(MODELS.keys()),
            value=list(MODELS.keys())[0],
            label="Modèle",
            interactive=True,
        )

    with gr.Row(equal_height=False):

        with gr.Column(scale=1, elem_classes=["vc-panel"]):
            gr.HTML(
                '<div class="vc-step-tag">Étape 01</div>'
                '<div class="vc-step-title">Enregistrer une voix</div>'
            )
            audio_in = gr.Audio(
                sources=["microphone", "upload"],
                type="numpy",
                label="Sample vocal (3–10 s)",
                value=default_audio_value,
            )
            ref_text = gr.Textbox(
                label="Transcript",
                placeholder="Tape exactement ce qui est dit dans l'audio …",
                lines=3,
                value=DEFAULT_REF_TEXT if default_audio_value else "",
            )
            reg_btn = gr.Button("Enregistrer la voix", variant="primary")
            reg_status = gr.Textbox(
                label="", interactive=False, elem_classes=["vc-status"],
            )

        with gr.Column(scale=1, elem_classes=["vc-panel"]):
            gr.HTML(
                '<div class="vc-step-tag">Étape 02</div>'
                '<div class="vc-step-title">Générer du texte parlé</div>'
            )
            target_text = gr.Textbox(
                label="Texte à synthétiser",
                placeholder="Tape n'importe quoi — ce sera dit avec la voix clonée …",
                lines=4,
            )
            lang_dd = gr.Dropdown(
                choices=LANGUAGES, value="Auto", label="Langue",
            )
            gen_btn = gr.Button("Générer", variant="primary")
            audio_out = gr.Audio(label="Résultat", type="filepath")
            gen_status = gr.Textbox(
                label="", interactive=False, elem_classes=["vc-status"],
            )

    gr.HTML(
        '<div class="vc-footer">'
        'Qwen3-TTS · NeuTTS Air · Sopro &middot; 100% local sur ton appareil'
        '</div>'
    )

    reg_btn.click(
        register_voice, [model_dd, audio_in, ref_text], [reg_status],
    )
    gen_btn.click(
        generate_speech, [model_dd, target_text, lang_dd],
        [audio_out, gen_status],
    )


# ── Main ──────────────────────────────────────────────────────────

if __name__ == "__main__":
    ts_host = _detect_tailscale()
    if ts_host:
        print(f"[vc] Tailscale → https://{ts_host}/")
        print(f"[vc]   (tailscale serve --bg --https 443 http://localhost:7860)")

    app.launch(
        server_name="0.0.0.0",
        server_port=7860,
        theme=THEME,
        css=CSS,
    )
