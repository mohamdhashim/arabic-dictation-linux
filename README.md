# Arabic Dictation for Linux

Real-time Arabic (Egyptian dialect) dictation on Linux. It runs fully locally on your GPU and types the transcribed text straight into whatever window has focus. No cloud, no clipboard.

- **Model:** [CohereLabs/cohere-transcribe-arabic-07-2026](https://huggingface.co/CohereLabs/cohere-transcribe-arabic-07-2026) (INT4 quantized by default)
- **Tested on:** Fedora 42 · RTX 2060 6 GB · Wayland/GNOME
- **Setup script supports:** Fedora and Ubuntu/Debian

---

## How it works

```
Mic → PipeWire → vocalinux (push-to-talk)
                     ↓ HTTP POST (WAV)
              Cohere ASR server (Docker, GPU)
                     ↓ {"text": "..."}
              vocalinux → ydotool → active window
```

The ASR server only listens on `127.0.0.1:8765`, so nothing is exposed to your network.

---

## Requirements

- NVIDIA GPU with 3+ GB VRAM and the NVIDIA driver already installed
- Docker and Docker Compose
- PipeWire audio (default on Fedora 34+ and Ubuntu 22.10+)
- A free HuggingFace account with access to the gated model

`setup.sh` installs the NVIDIA container toolkit, ydotool and vocalinux for you.

---

## Quick start

### 1. Accept the model license

Open the [model page](https://huggingface.co/CohereLabs/cohere-transcribe-arabic-07-2026) and click **Agree and access repository**.

### 2. Create a HuggingFace token

Go to [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens) and create a new token. Read access is enough.

### 3. Clone and configure

```bash
git clone https://github.com/mohamdhashim/arabic-dictation-linux
cd arabic-dictation-linux

cp .env.example .env
# Edit .env and set HF_TOKEN to your token
```

### 4. Install the host tools

```bash
chmod +x setup.sh
./setup.sh
```

This installs the NVIDIA container toolkit, ydotool (plus a `ydotoold` user service), and vocalinux in its own virtualenv. It also sets up `/dev/uinput` permissions and, if it finds a USB mic, makes it your default input.

> If the script says you were added to the `input` group, log out and back in before continuing.

### 5. Start the ASR server

```bash
docker compose up -d
```

The first run downloads the model (about 4 GB) and takes a minute or so to load. Later starts use the cached copy.

Check that it is ready:

```bash
curl http://127.0.0.1:8765/health
# → {"status":"ok","device":"cuda","model":"...","vram_gb":1.56}
```

### 6. Launch vocalinux

From your app menu, or:

```bash
~/.local/share/vocalinux/venv/bin/vocalinux-gui
```

**Default shortcut:** double-tap `Ctrl` to start and stop recording.

---

## Using the API directly

The server also exposes an OpenAI-compatible endpoint, so you can use it from any client or script:

```bash
curl -F file=@sample.wav -F language=ar \
  http://127.0.0.1:8765/v1/audio/transcriptions
# → {"text": "..."}
```

| Endpoint | Method | Purpose |
|---|---|---|
| `/inference` | POST | Used by vocalinux |
| `/v1/audio/transcriptions` | POST | OpenAI-compatible transcription |
| `/health` | GET | Readiness check, shows device and VRAM |

Send audio as WAV. The server converts it to 16 kHz mono and splits long recordings into 28-second chunks.

---

## Resource usage

| Mode | VRAM | RAM overhead |
|---|---|---|
| Not running | 1.0 GB (system) | none |
| INT4 (default) | 2.8 GB | +1.0 GB |
| INT8 | 3.6 GB | +1.0 GB |

INT8 gives slightly better quality. To switch, edit `server.py`:

```python
# change this line:
bnb_config = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_compute_dtype=torch.bfloat16)
# to:
bnb_config = BitsAndBytesConfig(load_in_8bit=True)
```

Then rebuild: `docker compose up -d --build`

---

## Stopping

```bash
docker compose down              # stop the ASR server
systemctl --user stop ydotoold   # stop the text injector
```

---

## Troubleshooting

**Crash, or the wrong mic is used**
vocalinux uses the system default input, and the bundled config sets `device_index` to `null` on purpose. Set your mic as the default:

```bash
pactl list sources short          # find your mic name
pactl set-default-source <name>   # set it as default
```

**Text is not being typed**
Check that `ydotoold` is running and that you can write to `/dev/uinput`:

```bash
systemctl --user status ydotoold
ls -l /dev/uinput   # should show group: input
groups              # you should be in the input group
```

**CUDA not found in Docker**
Make sure the NVIDIA container toolkit is installed and Docker can see the GPU:

```bash
docker run --rm --gpus all nvidia/cuda:12.1.1-base-ubuntu22.04 nvidia-smi
```

**Model download fails (401/403)**
- Confirm you accepted the license on the HuggingFace model page.
- Check that the token in `.env` is valid and has read access.

---

## Project layout

| Path | Purpose |
|---|---|
| `server.py` | FastAPI ASR server that wraps the model |
| `Dockerfile`, `docker-compose.yml` | Container build and GPU runtime config |
| `setup.sh` | Host setup: container toolkit, ydotool, vocalinux, mic |
| `config/vocalinux.json` | vocalinux config copied to `~/.config/vocalinux/` |
| `.env.example` | Template for your HuggingFace token |
| `docs/SETUP.md` | Technical reference: bugs found, fixes, architecture |

---

## Technical reference

See [`docs/SETUP.md`](docs/SETUP.md) for the full technical write-up, including every bug encountered, the fixes applied and the architecture decisions. It is written for anyone (or any LLM) continuing work on the project.
