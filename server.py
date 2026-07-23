import gc
import io
import logging
import os

import numpy as np
import soundfile as sf
import torch
import uvicorn
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import JSONResponse
from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor, BitsAndBytesConfig

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

MODEL_ID = "CohereLabs/cohere-transcribe-arabic-07-2026"
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

logger.info(f"Loading {MODEL_ID} on {DEVICE} (INT4 quantized)")
processor = AutoProcessor.from_pretrained(MODEL_ID, trust_remote_code=True)
bnb_config = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_compute_dtype=torch.bfloat16)
asr_model = AutoModelForSpeechSeq2Seq.from_pretrained(
    MODEL_ID,
    trust_remote_code=True,
    quantization_config=bnb_config,
    low_cpu_mem_usage=True,
    device_map="auto",
)
asr_model.eval()
gc.collect()
torch.cuda.empty_cache()
logger.info(f"Model ready — VRAM: {torch.cuda.memory_allocated() / 1e9:.2f} GB")

# 28s chunks — processor has a 30s hard limit
CHUNK_SAMPLES = 16000 * 28

app = FastAPI()
torch.set_grad_enabled(False)


def load_audio(data: bytes) -> np.ndarray:
    buf = io.BytesIO(data)
    samples, sr = sf.read(buf, dtype="float32", always_2d=True)
    samples = samples.mean(axis=1)
    if sr != 16000:
        target_len = int(len(samples) * 16000 / sr)
        samples = np.interp(
            np.linspace(0, len(samples) - 1, target_len),
            np.arange(len(samples)),
            samples,
        )
    return samples.astype(np.float32)


async def _transcribe(audio_bytes: bytes) -> str:
    waveform = load_audio(audio_bytes)
    chunks = [waveform[i:i + CHUNK_SAMPLES] for i in range(0, len(waveform), CHUNK_SAMPLES)]
    parts = []
    for chunk in chunks:
        inputs = processor(chunk, sampling_rate=16000, return_tensors="pt")
        input_features = inputs.input_features.to(DEVICE, dtype=torch.bfloat16)
        generated_ids = asr_model.generate(input_features, max_new_tokens=4096)
        part = processor.batch_decode(generated_ids, skip_special_tokens=True)[0].strip()
        parts.append(part)
    text = " ".join(p for p in parts if p)
    logger.info(f"Transcribed ({len(chunks)} chunk(s)): {text!r}")
    return text


@app.post("/inference")
async def transcribe_inference(
    file: UploadFile = File(...),
    language: str = Form(default="ar"),
    model: str = Form(default="whisper-1"),
):
    audio_bytes = await file.read()
    logger.info(f"Received {len(audio_bytes)} bytes")
    try:
        return {"text": await _transcribe(audio_bytes)}
    except Exception as e:
        logger.exception(e)
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.post("/v1/audio/transcriptions")
async def transcribe_openai(
    file: UploadFile = File(...),
    language: str = Form(default="ar"),
    model: str = Form(default="whisper-1"),
):
    audio_bytes = await file.read()
    logger.info(f"Received {len(audio_bytes)} bytes")
    try:
        return {"text": await _transcribe(audio_bytes)}
    except Exception as e:
        logger.exception(e)
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.get("/health")
def health():
    vram = torch.cuda.memory_allocated() / 1e9 if DEVICE == "cuda" else 0
    return {"status": "ok", "device": DEVICE, "model": MODEL_ID, "vram_gb": round(vram, 2)}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8765, log_level="info")
