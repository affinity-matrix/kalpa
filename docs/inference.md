# Inference Server

The inference server is a FastAPI app running on a RunPod A100 80GB pod. The LTX-2.3
model and the collection's style LoRA are loaded into GPU memory on startup and stay
there for the duration of the demo. Jobs are queued and processed one at a time.

---

## Starting the Server

```bash
# RunPod (primary)
./scripts/start-inference-runpod.sh --collection oregon-coast

# Lambda Labs (secondary)
./scripts/start-inference-lambda.sh --collection oregon-coast
```

The script:
1. Creates an A100 pod on RunPod/Lambda
2. Gets the pod's public IP address
3. Prints the inference server URL — **copy this and update `INFERENCE_SERVER_URL` in your Vercel environment variables**
4. Polls `/health` every 30s until the server reports `status: "online"`
5. Exits (the pod keeps running)

**Note:** Each new pod gets a new IP. After starting the server, you must update
`INFERENCE_SERVER_URL` in both your local `.env` and the Vercel project environment
settings. The web app uses this URL to proxy requests.

**Pre-warm time:** ~15–20 minutes from pod creation to `status: "online"`. Plan
accordingly before a demo.

---

## Stopping the Server

```bash
# RunPod
./scripts/stop-inference-runpod.sh --collection oregon-coast

# Lambda Labs
./scripts/stop-inference-lambda.sh --collection oregon-coast
```

If a job is in progress, the script will warn you and ask for confirmation.

**Cost:** A100 pods cost ~$3–4/hour on RunPod. Always stop the server after a demo.

---

## API Reference

All endpoints are on port 8080. The `POST /inference` endpoint requires authentication.

### POST /inference

Queue a video generation job.

**Headers:**
```
X-API-Key: <INFERENCE_API_KEY>
Content-Type: application/json
```

**Request body:**
```json
{
  "job_id": "abc123",
  "collection": "oregon-coast",
  "video_prompt": "KALPA_COAST aerial coastline, dramatic cliffs, crashing waves"
}
```

**Response:**
```json
{
  "job_id": "abc123",
  "status": "queued"
}
```

Returns immediately. The job runs asynchronously in the background worker.

---

### GET /health

Liveness check. No authentication required.

**Response while loading:**
```json
{
  "status": "loading",
  "collection": null,
  "queue_depth": 0
}
```

**Response when ready:**
```json
{
  "status": "online",
  "collection": "oregon-coast",
  "queue_depth": 0
}
```

`queue_depth` is the number of jobs waiting (not counting the one currently running).
The web app polls this endpoint every 5s while `status != "online"`.

---

### GET /status/{job_id}

Get the status of a job. No authentication required.

**Response (pending):**
```json
{
  "job_id": "abc123",
  "status": "pending"
}
```

**Response (running):**
```json
{
  "job_id": "abc123",
  "status": "running"
}
```

**Response (complete):**
```json
{
  "job_id": "abc123",
  "status": "complete",
  "gcs_path": "gs://kalpa-assets/outputs/oregon-coast/abc123.mp4",
  "shelby_video": "outputs/oregon-coast/abc123.mp4",
  "shelby_metadata": "outputs/oregon-coast/abc123-metadata.json"
}
```

**Response (failed):**
```json
{
  "job_id": "abc123",
  "status": "failed",
  "error": "CUDA out of memory"
}
```

---

## Job Lifecycle

```
POST /inference received
  └─ job added to asyncio.Queue
  └─ returns { status: "queued" } immediately

Background worker (runs continuously):
  └─ pulls next job from queue
  └─ sets job status → "running"
  └─ calls pipeline.generate(job)
       ├─ Stage 1: TI2VidTwoStagesPipeline
       │   ├─ LTX-2.3 T2V: 121 frames @ 24fps → 960×544 tensor (40 denoising steps)
       │   └─ Spatial upscale: 960×544 → 1920×1088
       ├─ torch.cuda.empty_cache()
       └─ ffmpeg: 1920×1088 → 1920×1080 (crop 4px top + bottom)
  └─ uploads output.mp4 to GCS
  └─ uploads output.mp4 to Shelby
  └─ sets job status → "complete" with GCS + Shelby paths
  └─ pulls next job from queue (or waits)
```

Only one job runs at a time. Concurrent requests queue behind the running job.
`GET /status/:id` reflects real-time progress.

---

## Pipeline Implementation

The pipeline is implemented in `inference/pipeline.py`. Key details:

### TI2VidTwoStagesPipeline

Uses the `TI2VidTwoStagesPipeline` class from `ltx_pipelines`, which runs both T2V
generation and spatial upscaling in a single call. The two stages share the same
model weights, so there is no separate upscaler checkpoint to manage.

```python
from ltx_pipelines.ti2vid_two_stages import TI2VidTwoStagesPipeline

pipeline = TI2VidTwoStagesPipeline.from_pretrained(
    model_path,
    lora_path=lora_path,
    lora_strength=0.8,
    torch_dtype=torch.bfloat16,
    device="cuda",
)
```

### Generation Parameters

```python
result = pipeline(
    prompt=video_prompt,
    negative_prompt="worst quality, inconsistent motion, blurry, jittery, distorted",
    num_frames=121,           # 8×15+1 — satisfies frames % 8 == 1 constraint
    fps=24,
    width=960,                # after stage 1; upscaled to 1920 in stage 2
    height=544,               # after stage 1; upscaled to 1088 in stage 2
    num_inference_steps=40,
    guider_params=MultiModalGuiderParams(...),
)
```

### GPU Memory Management

Peak VRAM usage is ~76 GB on the A100 80GB. Two techniques are critical:

**`torch.no_grad()` — not `torch.inference_mode()`**

The inference server uses `torch.no_grad()` as the context manager, not the seemingly
equivalent `torch.inference_mode()`. With `inference_mode()`, PyTorch's autograd engine
can cache references to all 22B model weight tensors, holding ~74 GB of GPU memory
permanently. `no_grad()` prevents this, keeping memory within the A100's 80 GB limit.

```python
with torch.no_grad():
    result = pipeline(...)
```

**Cache clearing between stages**

```python
torch.cuda.empty_cache()  # called before and after each pipeline stage
```

**Memory diagnostics**

The server runs a background thread that samples GPU memory every 2s and logs it. On
OOM errors, it dumps the top 30 live CUDA allocations ≥ 100 MiB:

```
OOM snapshot — top allocations:
  74.2 GiB  ltx_pipelines.model  transformer.blocks.0.weight
  ...
```

### ffmpeg Crop

The spatial upscaler outputs 1920×1088, but 1080p is 1920×1080. A crop step removes
4 pixels from the top and 4 from the bottom:

```bash
ffmpeg -i input.mp4 \
  -vf "crop=1920:1080:0:4" \
  -c:v libx264 -crf 18 \
  output.mp4
```

---

## Startup Flow (startup-infer.sh)

When the pod boots, `startup-infer.sh` runs automatically:

```
1. Install dependencies (uv, Node.js, Shelby CLI)
2. Configure Shelby CLI from env vars
3. gsutil cp gs://kalpa-assets/models/ /workspace/models/
4. gsutil cp gs://kalpa-assets/loras/{collection}/ /workspace/lora/
5. pip install -e LTX-2/ (ltx_pipelines package)
6. uvicorn inference.server:app --host 0.0.0.0 --port 8080
```

The FastAPI app initializes immediately but returns `status: "loading"` from `/health`
until the model is fully loaded into GPU memory. `/health` returns `status: "online"`
when the first inference can begin.

---

## Output Files

For each completed job:

| File | Location |
|------|----------|
| Video | `gs://kalpa-assets/outputs/{collection}/{job_id}.mp4` |
| Metadata | `gs://kalpa-assets/outputs/{collection}/{job_id}-metadata.json` |
| Video (Shelby) | `outputs/{collection}/{job_id}.mp4` (30-day expiry) |
| Metadata (Shelby) | `outputs/{collection}/{job_id}-metadata.json` |

`metadata.json` shape:
```json
{
  "collection": "oregon-coast",
  "job_id": "abc123",
  "model": "ltx-2.3-22b-dev",
  "lora_blob": "loras/oregon-coast/lora.safetensors",
  "video_prompt": "KALPA_COAST aerial coastline, dramatic cliffs...",
  "resolution": "1080p",
  "fps": 24,
  "duration_seconds": 5,
  "created_at": "2026-04-16T00:00:00Z"
}
```

---

## Inference Timing

| Step | Duration |
|------|----------|
| Model load (startup) | ~15–20 min |
| T2V generation (40 steps, 121 frames) | ~5–8 min |
| Spatial upscale (built-in) | ~1–2 min |
| ffmpeg crop | ~30 s |
| GCS upload | ~30 s |
| Shelby upload | ~2–5 min |
| **Total per job** | **~8–12 min** |

---

## Environment Variables

Set these on the pod at creation time (handled by the start-inference scripts):

| Variable | Purpose |
|----------|---------|
| `GCS_BUCKET` | Source for model + LoRA download |
| `GCP_SA_KEY_B64` | Base64-encoded GCP service account JSON for GCS access |
| `INFERENCE_API_KEY` | Shared secret — checked against `X-API-Key` header |
| `COLLECTION_NAME` | Which collection's LoRA to load |
| `SHELBY_WALLET_PRIVKEY` | Aptos wallet private key for Shelby uploads |
| `SHELBY_WALLET_ADDRESS` | Aptos wallet address |
| `SHELBY_NETWORK` | Shelby network (`testnet`) |
