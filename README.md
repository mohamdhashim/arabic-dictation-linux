# Arabic Speech-to-Text Dictation

Real-time Arabic (Egyptian dialect) dictation on Linux — fully local, GPU-accelerated, injects text directly into any window.

**Model:** [CohereLabs/cohere-transcribe-arabic-07-2026](https://huggingface.co/CohereLabs/cohere-transcribe-arabic-07-2026)  
**Tested on:** Fedora 42 · RTX 2060 6 GB · Wayland/GNOME

---

## How it works

```
Mic → PipeWire → vocalinux (push-to-talk)
                     ↓ HTTP POST (WAV)
              Cohere ASR server (Docker, GPU)
                     ↓ {"text": "..."}
              vocalinux → ydotool → active window
```

---

## Requirements

- NVIDIA GPU with 3+ GB VRAM
- Docker + Docker Compose
- PipeWire audio (default on Fedora 34+, Ubuntu 22.10+)
- A HuggingFace account with access to the model (free, requires license acceptance)

---

## Setup

### 1. Accept the model license

Go to [the model page](https://huggingface.co/CohereLabs/cohere-transcribe-arabic-07-2026) and click **Agree and access repository**.

### 2. Get a HuggingFace token

Go to [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens) → New token (read access is enough).

### 3. Clone and configure

```bash
git clone https://github.com/YOUR_USERNAME/cohere-arabic-dictation
cd cohere-arabic-dictation

cp .env.example .env
# Edit .env and paste your HuggingFace token
```

### 4. Install host tools (vocalinux + ydotool)

```bash
chmod +x setup.sh
./setup.sh
```

> If prompted to log out — do so, then log back in before continuing.

### 5. Start the ASR server

```bash
docker compose up -d
```

The model downloads on first run (~4 GB). Subsequent starts use the cached version.

Check it's ready:
```bash
curl http://127.0.0.1:8765/health
# → {"status":"ok","device":"cuda","vram_gb":1.56}
```

### 6. Launch vocalinux

From your app menu, or:
```bash
~/.local/share/vocalinux/venv/bin/vocalinux-gui
```

**Default shortcut:** double-tap `Ctrl` to start/stop recording.

---

## Resource usage

| Mode | VRAM | RAM overhead |
|---|---|---|
| Not running | 1.0 GB (system) | — |
| INT4 (default) | 2.8 GB | +1.0 GB |
| INT8 | 3.6 GB | +1.0 GB |

To switch to INT8 (slightly better quality), edit `server.py`:
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
docker compose down      # stop ASR server
systemctl --user stop ydotoold
```

---

## Troubleshooting

**Crash / wrong mic being used**  
vocalinux uses the system default input. Set your mic as default:
```bash
pactl list sources short          # find your mic name
pactl set-default-source <name>   # set it as default
```

**Text not injecting**  
Check ydotoold is running:
```bash
systemctl --user status ydotoold
ls -l /dev/uinput   # should show group: input
groups              # you should be in the input group
```

**CUDA not found in Docker**  
Make sure nvidia-container-toolkit is installed and Docker can see the GPU:
```bash
docker run --rm --gpus all nvidia/cuda:12.1.1-base-ubuntu22.04 nvidia-smi
```

**Model download fails (401/403)**  
- Make sure you accepted the license on the HuggingFace model page  
- Verify your token in `.env` is valid and has read access

---

## Agent/LLM reference

See [`docs/SETUP.md`](docs/SETUP.md) for a full technical reference including all bugs encountered, fixes applied, and architecture decisions — intended for LLMs continuing work on this project.
