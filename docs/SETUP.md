# Arabic Speech-to-Text Dictation Setup

Reference document for any LLM continuing work on this session. Describes the full stack, file locations, known issues, and resource measurements.

---

## Goal

Real-time Arabic (Egyptian dialect) speech recognition on Linux (Wayland/GNOME), injecting transcribed text directly into any active window — no clipboard involvement.

**GPU:** NVIDIA RTX 2060 · 6 GB VRAM  
**OS:** Fedora 42 · Kernel 6.19 · PipeWire audio  

---

## Stack

```
Microphone (Logitech C270 webcam mic)
    ↓  PipeWire (audio routing)
    ↓  PyAudio device: system default → webcam
vocalinux-gui           — push-to-talk dictation frontend
    ↓  HTTP POST multipart/form-data (WAV, 16 kHz mono)
Cohere ASR server       — FastAPI on 127.0.0.1:8765
    ↓  CohereLabs/cohere-transcribe-arabic-07-2026 (INT4, CUDA)
    ↑  {"text": "..."}
vocalinux-gui
    ↓  ydotool type
ydotoold daemon         — writes to /dev/uinput
    ↓
Active window receives typed text
```

---

## Tools & Services

| Tool | Purpose | Source |
|---|---|---|
| **vocalinux** | Speech dictation GUI, push-to-talk, VAD | `~/.local/share/vocalinux/` |
| **ydotool / ydotoold** | Wayland text injection via `/dev/uinput` | System package |
| **CohereLabs/cohere-transcribe-arabic-07-2026** | Arabic ASR model (2B params, HuggingFace gated) | HuggingFace |
| **FastAPI + uvicorn** | HTTP wrapper exposing OpenAI-compatible ASR endpoint | `~/.local/share/cohere-asr/venv/` |
| **bitsandbytes** | INT4/INT8 quantization to reduce VRAM | pip |
| **transformers / accelerate** | Model loading with `device_map="auto"` | pip |
| **soundfile** | Audio decoding in the server (replaces torchaudio) | pip |
| **PipeWire** | System audio routing | System |
| **WirePlumber** | Sets persistent default audio source | System |

---

## Key Files

| File | Purpose |
|---|---|
| `~/.local/share/cohere-asr/server.py` | Cohere ASR FastAPI server (main file) |
| `~/.local/share/cohere-asr/venv/` | Python venv with torch+CUDA, transformers, fastapi, etc. |
| `~/.config/vocalinux/config.json` | vocalinux configuration |
| `~/.config/wireplumber/wireplumber.conf.d/51-default-source.conf` | Persistent default mic (webcam) |
| `~/.config/systemd/user/ydotoold.service` | ydotoold systemd user service |
| `/etc/udev/rules.d/60-uinput.rules` | `/dev/uinput` group permissions |

---

## Configuration

### vocalinux — `~/.config/vocalinux/config.json`

```json
{
  "speech_recognition": {
    "engine": "remote_api",
    "language": "auto",
    "remote_api_url": "http://127.0.0.1:8765",
    "remote_api_endpoint": "/inference"
  },
  "audio": {
    "device_index": null,
    "device_name": "pipewire"
  },
  "text_injection": {
    "copy_to_clipboard": false
  }
}
```

> **`device_index: null`** — critical. Uses system default input instead of a numeric index.  
> PipeWire device indices shift every time an audio app (including vocalinux's own `paplay` sound effects) opens or closes. A hardcoded index causes vocalinux to open the wrong device and crash with `free(): corrupted unsorted chunks`.

### WirePlumber default mic — `~/.config/wireplumber/wireplumber.conf.d/51-default-source.conf`

```
wireplumber.settings = {
  default.audio.source = "alsa_input.usb-046d_0825_3DB67550-02.mono-fallback"
}
```

Sets the Logitech C270 webcam mic as the persistent default PipeWire input source across reboots.

### `/dev/uinput` permissions — `/etc/udev/rules.d/60-uinput.rules`

```
KERNEL=="uinput", GROUP="input", MODE="0660"
```

User must be in the `input` group (`sudo usermod -aG input $USER`, then log out/in).

---

## Starting the Stack

### 1. Cohere ASR server

Requires a valid HuggingFace token with access to the gated model.  
**⚠️ Regenerate the token — the old one was shared in chat.**

```bash
HF_TOKEN=<your_hf_token> \
  ~/.local/share/cohere-asr/venv/bin/python \
  ~/.local/share/cohere-asr/server.py \
  > /tmp/cohere-asr.log 2>&1 &
```

Wait for `Uvicorn running on http://127.0.0.1:8765` in the log (~30–60 s for model load).

Health check:
```bash
curl http://127.0.0.1:8765/health
# → {"status":"ok","device":"cuda","model_id":"...","vram_gb":1.56}
```

### 2. ydotoold

```bash
systemctl --user start ydotoold
# or check: systemctl --user status ydotoold
```

### 3. vocalinux

Launch from the app menu or:
```bash
~/.local/share/vocalinux/venv/bin/vocalinux-gui
```

Default shortcut: **double-tap Ctrl** to toggle push-to-talk.

---

## Server Endpoints

| Endpoint | Method | Used by |
|---|---|---|
| `POST /inference` | multipart: `file`, `language`, `model` | vocalinux `remote_api` engine |
| `POST /v1/audio/transcriptions` | multipart: `file`, `language`, `model` | OpenAI-compatible clients |
| `GET /health` | — | monitoring / startup check |

Audio must be WAV format. Server resamples internally to 16 kHz mono if needed.  
Audio is split into 28-second chunks to respect the processor's 30-second hard limit.

---

## Resource Usage

All measurements on the same machine (RTX 2060 6 GB, 16 GB RAM).

### Baseline — no setup running

| Resource | Value |
|---|---|
| RAM used | 5.7 GB |
| RAM available | 9.9 GB |
| VRAM used | 1,052 MB |
| VRAM free | 4,685 MB |

### With INT8 quantization (`load_in_8bit=True`)

| Resource | Value | Delta vs baseline |
|---|---|---|
| RAM used | 6.7 GB | +1.0 GB |
| RAM available | 8.9 GB | −1.0 GB |
| VRAM used | 3,564 MB | **+2,512 MB** |
| VRAM free | 2,173 MB | −2,512 MB |
| Model VRAM | 2.34 GB | — |

### With INT4 quantization (`load_in_4bit=True`, current)

| Resource | Value | Delta vs baseline | Delta vs INT8 |
|---|---|---|---|
| RAM used | ~6.7 GB | +1.0 GB | no change |
| RAM available | ~8.9 GB | −1.0 GB | no change |
| VRAM used | 2,864 MB | **+1,812 MB** | **−700 MB** |
| VRAM free | 2,873 MB | −1,812 MB | +700 MB |
| Model VRAM | 1.56 GB | — | −780 MB |

**INT4 saves 780 MB VRAM vs INT8 with a small quality trade-off. Acceptable for Arabic ASR.**

---

## Known Issues & Fixes Applied

| Issue | Root cause | Fix |
|---|---|---|
| `free(): corrupted unsorted chunks` crash | vocalinux's `paplay` sound effects open PipeWire clients, shifting device indices; vocalinux then opens the wrong device | Set `device_index: null` in config + WirePlumber default source |
| `Input type (float) and bias type (BFloat16)` | INT8/INT4 model layers stay in bfloat16; passing float32 input_features causes dtype mismatch | Cast: `input_features.to(DEVICE, dtype=torch.bfloat16)` |
| Model only outputs ~8 words | No `max_new_tokens` + processor's 30 s hard limit truncating audio | Added `max_new_tokens=4096` + 28 s audio chunking |
| `AttributeError: 'str' object has no attribute 'generate'` | FastAPI `model` form field shadowed the global `model` variable | Renamed model variable to `asr_model` |
| `load_in_8bit=True` keyword error | Custom `CohereAsrForConditionalGeneration.__init__()` doesn't accept it directly | Use `quantization_config=BitsAndBytesConfig(...)` instead |
| vocalinux mic at 0% audio | PyAudio cannot open ALSA hardware directly — PipeWire holds exclusive access | Use PipeWire virtual device (system default), not `hw:X,X` |
| Text injection not working on Wayland | `wtype` requires compositor virtual-keyboard protocol support | Use `ydotool` + `ydotoold` daemon instead |
| Server 500 on audio decode | `torchaudio.load` using torchcodec backend failed on raw bytes | Switched to `soundfile.read()` |

---

## Possible Future Improvements

- **Auto-start server on login** via a systemd user service (same pattern as ydotoold)
- **Store HF token** in `~/.config/cohere-asr/token` and read it in the server, avoid passing on command line
- **INT4 + NF4** (`bnb_4bit_quant_type="nf4"`) for slightly better quality at same VRAM
- **Double quantization** (`bnb_4bit_use_double_quant=True`) for ~0.1 GB additional VRAM saving
