# Kalpa — LTX-2.3 Video Generation Pipeline Spec

## Vision

A live demo of agentic video generation on Shelby Protocol. Agents (or humans) pay X402
to access assets at every stage of the pipeline. Every asset — dataset, LoRA weights,
inference runs, output derivatives — is a monetizable unit on Shelby. Agents discover,
purchase, and build on each other's work autonomously.

---

## System Architecture

```
┌──────────────────────────────────────────┐
│         Next.js Web App (Vercel)         │
│                                          │
│  /health online  →  prompt form          │
│  /health offline →  "Demo is offline"    │
│                                          │
│  POST /api/inference                     │
│    - verify X402 payment (in progress)   │
│    - forward to inference server         │
│      with shared API key                 │
│                                          │
│  GET /api/status/:jobId                  │
│    - proxy to inference server           │
│    - generate signed GCS URL on complete │
└────────────────┬─────────────────────────┘
                 │ HTTP (RunPod public IP)
┌────────────────▼─────────────────────────┐
│     FastAPI Inference Server             │
│     RunPod A100 80GB — on-demand         │
│                                          │
│  POST /inference  →  queue job           │
│  GET  /health     →  online | loading    │
│  GET  /status/:id →  pending | complete  │
│                                          │
│  Model pre-loaded in GPU memory          │
│  (~15 min pre-warm on startup)           │
│  Uploads output to GCS + Shelby          │
└────────────────┬─────────────────────────┘
                 │
┌────────────────▼─────────────────────────┐
│            GCS + Shelby                  │
│                                          │
│  GCS: models, LoRAs, outputs (primary)   │
│  Shelby: LoRAs + outputs (primary in v2) │
└──────────────────────────────────────────┘

┌──────────────────────────────────────────┐
│        Training Pipeline (separate)      │
│        CLI — run manually as needed      │
│        RunPod H100 80GB — self-terminates│
└──────────────────────────────────────────┘
```

---

## Model Stack

| Component | Checkpoint | Notes |
|-----------|-----------|-------|
| Base model | `Lightricks/LTX-2.3` — `ltx-2.3-22b-dev` | 22B params, ~44 GB bf16 |
| Spatial upscaler | `ltx-2.3-spatial-upscaler-x2-1.1` | Built into `TI2VidTwoStagesPipeline` |
| Text encoder | `google/gemma-3-12b-it-qat-q4_0-unquantized` | Gated model — accept terms on HF |

> **Temporal upscaler dropped:** `ltx-2.3-temporal-upscaler-x2` has no public API in
> `ltx_pipelines`. Video is generated at native 24fps.

**No quantization.** Full bf16. Requires 80 GB VRAM.

---

## Hardware

| Role | Provider | Instance | VRAM | Notes |
|------|----------|----------|------|-------|
| Training | RunPod (primary) / Lambda Labs (secondary) | H100 80GB | 80 GB | Self-terminates on completion |
| Inference | RunPod (primary) / Lambda Labs (secondary) | A100 80GB | 80 GB | On-demand; stays up until stopped |

---

## GCS Bucket Layout

```
gs://kalpa-assets/
  models/
    ltx-2.3-22b-dev/                  # base model weights (~44 GB)
    ltx-2.3-spatial-upscaler-x2/
    gemma-encoder/
  collections/
    {name}/
      collection.yaml                 # source of truth, updated by training scripts
      footage/                        # 720p clips downloaded from HF during training
  loras/
    {name}/
      lora.safetensors
      metadata.json
  outputs/
    {name}/
      {job_id}.mp4
      {job_id}-metadata.json
```

---

## Shelby Storage Convention

```
loras/{collection-name}/lora.safetensors
loras/{collection-name}/metadata.json

outputs/{collection-name}/{job_id}.mp4
outputs/{collection-name}/{job_id}-metadata.json
```

Currently GCS is the primary artifact store; Shelby is written to in parallel.
In v2, this inverts: Shelby becomes the primary store and GCS serves as backup.

---

## Training Pipeline

**Run:** `./scripts/train-runpod.sh --collection <name>` (or `train-lambda.sh`)

A RunPod H100 pod is created, downloads LTX-2.3 weights from GCS, downloads footage
from HuggingFace, trains a style LoRA via `ltx-trainer`, uploads weights to GCS +
Shelby, writes artifact IDs back to `collection.yaml`, and self-terminates.

Total duration: ~1.5–2.5 hours.

See [docs/training.md](docs/training.md) for the full step-by-step breakdown.

---

## Inference Pipeline

**Generation parameters:**

| Step | Detail |
|------|--------|
| Model | LTX-2.3 T2V + style LoRA (0.8 strength) |
| Frames | 121 (8×15+1) at 24fps native ≈ 5s |
| Spatial upscale | Built into `TI2VidTwoStagesPipeline`: 960×544 → 1920×1088 |
| ffmpeg crop | 1920×1088 → 1920×1080 (removes 4px top and bottom) |
| Output | ~5s, 1080p, 24fps MP4 |

The A100 runs a FastAPI server with the model pre-loaded in GPU memory. Jobs are queued
and processed sequentially. On completion, the server uploads the output to GCS and
Shelby before marking the job complete.

See [docs/inference.md](docs/inference.md) for the full API reference and job lifecycle.

---

## Web App

Next.js 15 on Vercel. The home page polls `/api/health` every 5s while offline and
shows the prompt form when the inference server is up. Submitting a prompt posts to
`/api/inference`, which verifies X402 payment (currently disabled) then proxies to the
inference server. The job page polls `/api/status/:id` every 10s until complete, then
generates a signed GCS URL for video playback.

See [docs/web-app.md](docs/web-app.md) for the full component and API route breakdown.

---

## X402 Integration

| Phase | Gated asset | Status |
|-------|-------------|--------|
| v1 | Inference (per run) | In progress — `X402_ENFORCE=false` currently |
| v2 | LoRA weights (per access) | Planned |
| v3 | Dataset, training job, derivatives | Planned |

The goal is a fully agentic economy where autonomous agents buy and sell access at
every stage of the pipeline.

---

## Scripts

| Script | Run on | Purpose |
|--------|--------|---------|
| `scripts/setup-models.sh` | Mac | One-time: download LTX-2.3 weights to GCS |
| `scripts/train-runpod.sh` | Mac | Train a LoRA on RunPod H100 |
| `scripts/train-lambda.sh` | Mac | Train a LoRA on Lambda Labs H100 |
| `scripts/start-inference-runpod.sh` | Mac | Start inference server on RunPod A100 |
| `scripts/start-inference-lambda.sh` | Mac | Start inference server on Lambda Labs A100 |
| `scripts/stop-inference-runpod.sh` | Mac | Terminate RunPod inference instance |
| `scripts/stop-inference-lambda.sh` | Mac | Terminate Lambda Labs inference instance |
| `scripts/startup-train.sh` | H100 | Full training pipeline (boot script — not run manually) |
| `scripts/startup-infer.sh` | A100 | Model download + FastAPI start (boot script — not run manually) |
| `scripts/logs.sh` | Mac | Tail logs for a running instance |
| `scripts/status.sh` | Mac | Show status of running instances |
| `scripts/kill.sh` | Mac | Force-terminate an instance |

---

## Future Work

- **v2 storage:** Shelby as primary artifact store; GCS as backup
- **v2 X402:** Gate LoRA weights access via `lora_access_price_apt` in collection YAML
- **v2 audio:** Separate audio model (MusicGen / ElevenLabs) → audio-conditioned video via `a2vid_two_stage`
- **v3:** Gate dataset download, training job trigger, output derivatives
- **Full agentic loop:** Agent A buys dataset → trains LoRA → sells access → Agent B buys LoRA → runs inference → sells output → Agent C creates derivative
- **Multi-collection:** Additional styles, locations, and aesthetics using same pipeline
- **Motion + Subject LoRAs:** See LoRA type reference in [docs/collections.md](docs/collections.md)
