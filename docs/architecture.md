# Architecture

Kalpa is three loosely-coupled services plus shared storage. They communicate only
through HTTP and GCS — there is no message queue or shared database.

---

## Components

### 1. Web App (Vercel — always-on)

Next.js 15 app deployed to Vercel. It is the only public-facing surface. It:

- Shows the prompt form when the inference server is online
- Accepts video generation requests and verifies payment (X402)
- Proxies job creation and status polling to the inference server
- Generates signed GCS URLs so the browser can stream completed videos

The web app never touches model weights or runs any ML code. It holds the API key
that authenticates with the inference server.

### 2. Inference Server (RunPod A100 — on-demand)

A FastAPI server running on a RunPod A100 80GB pod. It:

- Loads LTX-2.3 (22B) + the collection's style LoRA into GPU memory on startup
- Accepts generation jobs over HTTP (authenticated by shared API key)
- Processes jobs one at a time through the full pipeline: T2V → spatial upscale → ffmpeg
- Uploads completed videos to GCS and Shelby
- Exposes `/health` for liveness polling

The pod is created manually before a demo and terminated afterward. It is not running
when the demo is idle — the web app shows "Demo is offline" in that state.

### 3. Training Pipeline (RunPod H100 — on-demand, self-terminates)

A set of bash scripts that spin up a RunPod H100 pod from your Mac, run the full
training pipeline on the pod, and clean up. The pod:

- Downloads model weights from GCS (~47 GB)
- Downloads footage from HuggingFace
- Builds a `dataset.jsonl` with captions prepended with the style trigger token
- Preprocesses (trims clips to valid frame counts, computes latents)
- Trains a style LoRA via `ltx-trainer`
- Uploads weights to GCS + Shelby
- Writes Shelby artifact IDs back to `collection.yaml` in GCS
- Self-terminates

You do not need to stay connected. The orchestration scripts (`train-runpod.sh`,
`train-lambda.sh`) poll the provider API until the pod terminates, then pull the
updated `collection.yaml`.

### 4. GCS Bucket (`gs://kalpa-assets`)

The shared artifact store. All three services read from and write to it:

- Model weights are written once by `setup-models.sh` and read by every training and inference pod
- Collection footage is written during training and can be reused across runs
- LoRA weights are written by training and read by inference
- Video outputs are written by inference and read by Vercel (via signed URL)

### 5. Shelby Protocol

Every LoRA weight file and every video output is also uploaded to Shelby with a named
blob path (see naming convention below). Currently Shelby runs in parallel with GCS —
assets are served from GCS. In v2, Shelby becomes the primary store.

---

## Communication Paths

```
Browser  ──HTTPS──►  Vercel (Next.js)
                          │
                          │ HTTP + X-API-Key header
                          ▼
                  RunPod Inference Server (FastAPI :8080)
                          │
                          ├── reads: gs://kalpa-assets/models/
                          ├── reads: gs://kalpa-assets/loras/{name}/
                          ├── writes: gs://kalpa-assets/outputs/{name}/{job_id}.mp4
                          └── writes: Shelby outputs/{name}/{job_id}.mp4

Mac (CLI) ──RunPod API──► H100 Training Pod
                          │
                          ├── reads: gs://kalpa-assets/models/
                          ├── reads: HuggingFace dataset
                          ├── writes: gs://kalpa-assets/loras/{name}/lora.safetensors
                          ├── writes: gs://kalpa-assets/collections/{name}/collection.yaml (artifacts)
                          └── writes: Shelby loras/{name}/lora.safetensors

Vercel ──GCS Signed URL──► Browser (video playback)
```

---

## Data Flow: Training

```
1. Mac: ./scripts/train-runpod.sh --collection oregon-coast
   │
   ├─ Reads collections/oregon-coast/collection.yaml
   ├─ Creates RunPod H100 pod with collection name as metadata
   └─ Polls pod until it terminates

2. H100 Boot (startup-train.sh):
   │
   ├─ Downloads LTX-2.3 weights from GCS (~47 GB)
   ├─ Downloads footage from HuggingFace (148 clips, 720p)
   ├─ scripts/build_dataset.py → dataset.jsonl
   │    (prepends KALPA_COAST to each clip's scene_description caption)
   ├─ process_dataset.py → precomputes latents at 960x544x121
   ├─ ltx-trainer → lora.safetensors (500–1500 steps)
   ├─ gsutil cp lora.safetensors → gs://kalpa-assets/loras/oregon-coast/
   ├─ shelby upload lora.safetensors loras/oregon-coast/lora.safetensors
   ├─ Updates collection.yaml in GCS with Shelby blob IDs
   └─ Self-terminates

3. Mac: train-runpod.sh sees pod terminated
   └─ Downloads updated collection.yaml (now has artifacts filled in)
```

---

## Data Flow: Inference

```
1. Browser: POST /api/inference { prompt: "KALPA_COAST dramatic cliffs..." }
   │
   └─ Vercel: verifies X402 payment (currently disabled, X402_ENFORCE=false)
              generates job_id
              POST http://{pod-ip}:8080/inference { job_id, prompt, collection }
              returns { jobId } to browser

2. Browser: redirected to /job/{jobId}, polls GET /api/status/{jobId} every 10s

3. Inference server background worker:
   │
   ├─ TI2VidTwoStagesPipeline.generate()
   │   ├─ Stage 1: LTX-2.3 T2V (121 frames @ 24fps) → 960x544 tensor
   │   └─ Stage 2: Spatial upscale → 1920x1088
   ├─ torch.cuda.empty_cache() between stages
   ├─ ffmpeg: 1920x1088 → 1920x1080 (crop 4px top + bottom)
   ├─ gsutil cp output.mp4 → gs://kalpa-assets/outputs/oregon-coast/{job_id}.mp4
   ├─ shelby upload output.mp4 outputs/oregon-coast/{job_id}.mp4 -e "in 30 days"
   └─ marks job complete with GCS path

4. Vercel: GET /api/status/{jobId}
   └─ Proxies to inference server
      If complete: generates signed GCS URL (15-min expiry)
      Returns status + signed URL to browser

5. Browser: VideoPlayer renders <video src={signedUrl} />
```

---

## Asset Lifecycle

| Asset | Created by | Stored in | Read by | Lifecycle |
|-------|-----------|-----------|---------|-----------|
| Model weights | `setup-models.sh` | GCS `models/` | Training pod, Inference pod | Permanent — written once |
| Training footage | `startup-train.sh` | GCS `collections/{name}/footage/` | Training pod | Per collection — reused on retrain |
| Preprocessed latents | `startup-train.sh` | H100 disk (temp) | Training pod | Discarded on pod termination |
| LoRA weights | `startup-train.sh` | GCS `loras/{name}/` + Shelby | Inference pod | Per collection — updated on retrain |
| Video output | Inference server | GCS `outputs/{name}/` + Shelby | Vercel (signed URL) | Per job — 30-day Shelby expiry |
| `collection.yaml` | Human (template) / Training (artifacts) | GCS + local `collections/` | All scripts | Updated on each training run |

---

## Storage: Current vs. v2

**Current (v1):**
- GCS is primary — all services read from GCS
- Shelby receives uploads in parallel (training and inference both write to Shelby)
- Videos are served from GCS via Vercel-generated signed URLs

**Planned (v2):**
- Shelby is primary — services read from Shelby
- GCS is backup / fallback
- Videos served directly from Shelby blobs
- LoRA weights gated by X402 (`lora_access_price_apt` in collection YAML)

---

## X402 Payment Flow

**Current state (X402_ENFORCE=false):**
```
Browser → POST /api/inference → Vercel skips payment check → inference server
```

**Target state (X402_ENFORCE=true):**
```
Browser → POST /api/inference
  Vercel: extract X402 payment header from request
  If missing: return 402 with { price: 0.01 APT, payTo: wallet, network: aptos:testnet }
  Browser: wallet signs payment, retries with X402 header
  Vercel: verify payment via X402 facilitator
  If valid: forward to inference server with X-API-Key
```

The inference server never handles payments — it only sees the shared API key.
All payment logic lives in `web/app/api/inference/route.ts` and `web/lib/x402.ts`.

---

## Security Boundaries

| Boundary | Mechanism |
|----------|-----------|
| Browser → Vercel | HTTPS (Vercel-managed TLS) |
| Vercel → Inference server | Shared `INFERENCE_API_KEY` header |
| Inference server → GCS | GCP service account JSON (base64 env var on pod) |
| Vercel → GCS | GCP service account JSON (`GCP_SA_KEY` Vercel env var) |
| Training pod → GCS | GCP service account JSON (base64 env var on pod) |
| Shelby uploads | Aptos wallet private key (`SHELBY_WALLET_PRIVKEY` env var) |
| Browser → GCS (video) | Signed URLs generated by Vercel (15-min expiry) |

The Aptos wallet private key and API keys are never committed to the repo. They live
in `.env` (gitignored) and are passed to pods as environment variables at creation time.
