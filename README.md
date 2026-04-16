# Kalpa

Agentic video generation pipeline on [Shelby Protocol](https://shelby.network). Trains
style LoRAs on curated footage collections, generates text-to-video clips via an
X402-gated inference API, and publishes all artifacts to Shelby on Aptos.

**Model:** LTX-2.3-22b-dev (Lightricks, 22B) · **Output:** ~5s 1080p 24fps · **Infra:** RunPod H100 (training) + A100 (inference) · **Web app:** Next.js on Vercel

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [One-Time Setup](#one-time-setup)
   - [GCS Bucket](#1-gcs-bucket)
   - [GCP Service Account (Vercel)](#2-gcp-service-account-vercel)
   - [Aptos Wallet](#3-aptos-wallet)
   - [HuggingFace](#4-huggingface)
   - [Environment File](#5-environment-file)
   - [Download Models to GCS](#6-download-models-to-gcs)
   - [Deploy Web App](#7-deploy-web-app)
4. [Adding a Collection](#adding-a-collection)
5. [Training a LoRA](#training-a-lora)
6. [Running the Demo](#running-the-demo)
7. [Script Reference](#script-reference)
8. [Environment Variable Reference](#environment-variable-reference)
9. [Collection YAML Reference](#collection-yaml-reference)
10. [Further Reading](#further-reading)

---

## Architecture Overview

```
Web App (Vercel)
  └─ POST /api/inference   X402 payment check → forward to inference server
  └─ GET  /api/status/:id  proxy + generate signed GCS URL when complete

Inference Server (RunPod A100 80GB, on-demand during demo)
  └─ FastAPI, model pre-loaded in GPU memory (~15 min pre-warm)
  └─ Uploads output to GCS + Shelby on completion

Training Pipeline (RunPod H100 80GB, self-terminates)
  └─ Downloads footage from HuggingFace
  └─ Trains style LoRA via ltx-trainer
  └─ Uploads LoRA weights to GCS + Shelby
```

For a detailed breakdown see [docs/architecture.md](docs/architecture.md).

---

## Prerequisites

Install these tools on your Mac before starting:

| Tool | Install | Required for |
|------|---------|-------------|
| `gcloud` CLI | [cloud.google.com/sdk](https://cloud.google.com/sdk/docs/install) | GCS operations |
| `gsutil` | Included with gcloud | GCS operations |
| `node` ≥ 20 | [nodejs.org](https://nodejs.org) | Shelby CLI, web app |
| `vercel` CLI | `npm i -g vercel` | Web app deployment |
| `python3` ≥ 3.12 | [python.org](https://python.org) | Local script helpers |

Authenticate gcloud:
```bash
gcloud auth login
gcloud auth application-default login
```

You will also need accounts on:
- **RunPod** — primary GPU provider for training and inference
- **Lambda Labs** — secondary provider (keep functional; use if RunPod has no availability)

---

## One-Time Setup

These steps are done once per project, not per demo run.

### 1. GCS Bucket

Create the GCS bucket used for model weights, LoRAs, and video outputs:

```bash
gsutil mb -l us-central1 gs://kalpa-assets
```

### 2. GCP Service Account (Vercel)

Vercel needs read access to GCS to generate signed URLs for video playback.

```bash
# Create the service account
gcloud iam service-accounts create kalpa-vercel \
  --display-name="Kalpa Vercel SA"

# Grant read access to the bucket
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:kalpa-vercel@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.objectViewer"

# Download the key JSON
gcloud iam service-accounts keys create kalpa-vercel-key.json \
  --iam-account=kalpa-vercel@YOUR_PROJECT_ID.iam.gserviceaccount.com
```

The contents of `kalpa-vercel-key.json` go into `GCP_SA_KEY` in Vercel's environment
settings. Keep this file out of the repo (it's in `.gitignore`).

### 3. Aptos Wallet

Create an Aptos wallet for the pipeline. This wallet pays gas fees and ShelbyUSD for
Shelby uploads, and receives X402 inference payments.

```bash
# Use the Aptos CLI or any Aptos wallet tool to create a wallet
# Note the private key and address
```

Fund the wallet on **testnet**:
- **APT** (gas): [aptos.dev/network/faucet](https://aptos.dev/en/network/faucet)
- **ShelbyUSD** (storage): follow Shelby Protocol funding docs

> Before running a training job, verify that `shelby upload` works:
> ```bash
> echo "test" > /tmp/test.txt
> shelby upload /tmp/test.txt kalpa-test -e "in 1 hour"
> ```
> A failed Shelby upload at the end of a 2-hour H100 run is expensive to re-run.

### 4. HuggingFace

The Gemma text encoder is a gated model and requires explicit approval.

1. Create an account at [huggingface.co](https://huggingface.co)
2. Accept the model terms at `huggingface.co/google/gemma-3-12b-it-qat-q4_0-unquantized`
3. Generate a token at `huggingface.co/settings/tokens` → set as `HF_TOKEN` in `.env`

### 5. Environment File

```bash
cp .env.example .env
```

Edit `.env` and fill in all required values. See [Environment Variable Reference](#environment-variable-reference) below.

Also set up the web app env:
```bash
cd web
cp .env.local.example .env.local
# Fill in web/.env.local
```

### 6. Download Models to GCS

One-time download of ~47 GB from HuggingFace to your GCS bucket. Run from the repo root:

```bash
./scripts/setup-models.sh
```

**Required env vars:** `HF_TOKEN`, `GCS_BUCKET`

Downloads:
- `ltx-2.3-22b-dev.safetensors` (46.1 GB)
- `ltx-2.3-spatial-upscaler-x2-1.1.safetensors` (996 MB)
- `google/gemma-3-12b-it-qat-q4_0-unquantized` (~6 GB)

This takes 30–60 min. Models live at `gs://kalpa-assets/models/` and are reused by
every training and inference pod. You never download them again.

### 7. Deploy Web App

```bash
cd web
npm install    # or: pnpm install
vercel deploy
```

Set all variables from `web/.env.local.example` in Vercel project settings
(Settings → Environment Variables). The `INFERENCE_SERVER_URL` can be set to a
placeholder for now — the web app will show "Demo is offline" until the inference
server is running.

---

## Adding a Collection

Each footage collection gets a YAML config. The Oregon coast collection is provided
as an example at `collections/oregon-coast/collection.yaml`.

1. Create `collections/<name>/collection.yaml` — copy the Oregon coast file as a
   template and update:

   | Field | Description |
   |-------|-------------|
   | `name` | Slug — must match directory name |
   | `description` | Human-readable |
   | `hf_dataset` | HuggingFace dataset ID |
   | `hf_split` | Dataset split (usually `train`) |
   | `style_token` | Unique ALL_CAPS trigger word (e.g. `MY_STYLE`) |
   | `training.steps` | 1000–1500 for style LoRA |
   | `default_prompts.video` | Placeholder prompt (include the style token) |

2. Train the LoRA — see next section.

For full field documentation see [docs/collections.md](docs/collections.md).

---

## Training a LoRA

Training runs on a RunPod H100 pod, self-terminates on completion, and takes ~1.5–2.5 hours.

```bash
# RunPod (primary)
./scripts/train-runpod.sh --collection oregon-coast

# Lambda Labs (alternative)
./scripts/train-lambda.sh --collection oregon-coast
```

**Required env vars:** `GCS_BUCKET`, `HF_TOKEN`, `RUNPOD_API_KEY` (or `LAMBDA_API_KEY`),
`SHELBY_WALLET_PRIVKEY`, `SHELBY_WALLET_ADDRESS`, `SHELBY_NETWORK`

**What happens:**

1. Creates an H100 pod on RunPod/Lambda with the collection name as metadata
2. Pod boots, runs `startup-train.sh`:
   - Downloads model weights from GCS
   - Downloads footage from HuggingFace
   - Builds `dataset.jsonl` (captions prepended with style token)
   - Preprocesses video latents
   - Trains LoRA via `ltx-trainer`
   - Uploads weights to GCS + Shelby
   - Writes Shelby artifact IDs back to `collection.yaml` in GCS
   - Self-terminates
3. `train-runpod.sh` detects termination, downloads updated `collection.yaml`

**Monitor progress:**
```bash
./scripts/logs.sh --collection oregon-coast
```

For the full step-by-step breakdown see [docs/training.md](docs/training.md).

---

## Running the Demo

### Start the inference server

Run this ~20 minutes before your demo:

```bash
# RunPod (primary)
./scripts/start-inference-runpod.sh --collection oregon-coast

# Lambda Labs (alternative)
./scripts/start-inference-lambda.sh --collection oregon-coast
```

**Required env vars:** `GCS_BUCKET`, `RUNPOD_API_KEY` (or `LAMBDA_API_KEY`),
`INFERENCE_API_KEY`, `SHELBY_WALLET_PRIVKEY`, `SHELBY_WALLET_ADDRESS`, `SHELBY_NETWORK`

**What happens:**

1. Creates an A100 pod, retrieves its public IP
2. Prints the inference server URL — **update `INFERENCE_SERVER_URL` in Vercel env vars**
3. Pod boots, downloads model + LoRA from GCS, loads into GPU (~15–20 min)
4. Script polls `/health` until `status: "online"`, then exits
5. Web app detects the server and shows the prompt form

> After starting the server, you must update `INFERENCE_SERVER_URL` in your Vercel
> project settings to the new pod IP. The pod gets a new IP each time it starts.

**Tail startup logs:**
```bash
./scripts/watch-and-infer-runpod.sh --collection oregon-coast
```

### Stop the inference server

After your demo:

```bash
# RunPod
./scripts/stop-inference-runpod.sh --collection oregon-coast

# Lambda Labs
./scripts/stop-inference-lambda.sh --collection oregon-coast
```

The A100 costs ~$3–4/hr. Always stop it after a demo.

### Demo flow

1. Open the web app — the prompt form appears when `/health` is online
2. Enter a prompt including the style token (e.g. `KALPA_COAST dramatic cliffs...`)
3. Click Generate — X402 payment is required in production; `X402_ENFORCE=false` skips it
4. Redirected to `/job/<id>` — page polls every 10s
5. Video appears when complete (~8–12 min)

For troubleshooting and cost management see [docs/operations.md](docs/operations.md).

---

## Script Reference

| Script | Run on | Purpose | Duration |
|--------|--------|---------|----------|
| `scripts/setup-models.sh` | Mac | One-time: download LTX-2.3 weights to GCS | ~45 min |
| `scripts/train-runpod.sh` | Mac | Train a LoRA on RunPod H100 | ~2 hr |
| `scripts/train-lambda.sh` | Mac | Train a LoRA on Lambda Labs H100 | ~2 hr |
| `scripts/start-inference-runpod.sh` | Mac | Start inference server on RunPod A100 | ~20 min |
| `scripts/start-inference-lambda.sh` | Mac | Start inference server on Lambda Labs A100 | ~20 min |
| `scripts/stop-inference-runpod.sh` | Mac | Terminate RunPod inference instance | ~1 min |
| `scripts/stop-inference-lambda.sh` | Mac | Terminate Lambda Labs inference instance | ~1 min |
| `scripts/startup-train.sh` | H100 | Full training pipeline — boot script, not run manually | — |
| `scripts/startup-infer.sh` | A100 | Download model + LoRA, start FastAPI — boot script | — |
| `scripts/logs.sh` | Mac | Tail logs for a running instance | — |
| `scripts/status.sh` | Mac | Show running instances | — |
| `scripts/kill.sh` | Mac | Force-terminate a named instance | — |
| `scripts/check-gpus-runpod.sh` | Mac | Check H100/A100 availability on RunPod | — |

Boot scripts (`startup-train.sh`, `startup-infer.sh`) are uploaded to GCS and run
automatically on pods at boot. You never call them directly.

---

## Environment Variable Reference

Copy `.env.example` to `.env` and fill in all required values.

### GCS

| Variable | Required | Description |
|----------|----------|-------------|
| `GCS_BUCKET` | ✅ | GCS bucket including `gs://` prefix (e.g. `gs://kalpa-assets`) |
| `GCP_PROJECT` | ✅ | GCP project ID (for service account and GCS access) |
| `GCP_SA_KEY_B64` | ✅ | Base64-encoded GCP service account JSON — used by training and inference pods to access GCS. Generate: `base64 -i kalpa-vercel-key.json` |

### HuggingFace

| Variable | Required | Description |
|----------|----------|-------------|
| `HF_TOKEN` | ✅ | HuggingFace access token for the gated Gemma text encoder |

### Shelby / Aptos

| Variable | Required | Description |
|----------|----------|-------------|
| `SHELBY_NETWORK` | ✅ | Shelby/Aptos network — `testnet` or `shelbynet` |
| `SHELBY_WALLET_PRIVKEY` | ✅ | Aptos wallet private key (`0x...`) |
| `SHELBY_WALLET_ADDRESS` | ✅ | Aptos wallet address (`0x...`) |

### GPU Providers

| Variable | Required | Description |
|----------|----------|-------------|
| `RUNPOD_API_KEY` | ✅ (RunPod) | RunPod API key |
| `LAMBDA_API_KEY` | ✅ (Lambda) | Lambda Labs API key |

### Inference Server

| Variable | Required | Description |
|----------|----------|-------------|
| `INFERENCE_API_KEY` | ✅ | Shared secret between Vercel and the inference server. Generate: `openssl rand -hex 32` |
| `INFERENCE_SERVER_URL` | ✅ | Full URL of the running inference pod: `http://{pod-ip}:8080`. Updated each time a new pod is started. |

### Web App (Vercel) — set in `web/.env.local` or Vercel dashboard

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `INFERENCE_SERVER_URL` | ✅ | — | Full URL of inference server. Update in Vercel each time a new pod starts. |
| `INFERENCE_API_KEY` | ✅ | — | Same value as above |
| `GCP_PROJECT_ID` | ✅ | — | GCP project ID |
| `GCP_SA_KEY` | ✅ | — | Full JSON contents of the Vercel service account key, as a single-line string |
| `GCS_BUCKET` | ✅ | — | Bucket name **without** `gs://` prefix (e.g. `kalpa-assets`) |
| `INFERENCE_PRICE_APT` | ❌ | `0.01` | Price in APT per inference job |
| `X402_ENFORCE` | ❌ | `false` | Set to `true` to require real X402 payment |
| `X402_FACILITATOR_URL` | ❌ | — | X402 facilitator endpoint |
| `X402_PAYTO_ADDRESS` | ❌ | — | Aptos address receiving inference payments |
| `X402_NETWORK` | ❌ | `aptos:testnet` | X402 payment network |

---

## Collection YAML Reference

Full reference with annotated fields: [docs/collections.md](docs/collections.md)

Quick summary of the most-edited fields:

```yaml
name: oregon-coast              # slug — matches directory name
style_token: KALPA_COAST        # ALL_CAPS trigger word for all captions + prompts

training:
  steps: 1500                   # 1000–1500 for style LoRA
  rank: 32                      # 32 for style, 64 for subject/scene
  learning_rate: 5.0e-5

artifacts:                      # filled automatically by training script
  lora_gcs: null
  shelby_lora: null
  shelby_metadata: null
```

---

## Further Reading

| Document | Contents |
|----------|----------|
| [PIPELINE_SPEC.md](PIPELINE_SPEC.md) | High-level system overview |
| [docs/architecture.md](docs/architecture.md) | Component details, data flows, security boundaries |
| [docs/training.md](docs/training.md) | Training pipeline deep dive, step-by-step |
| [docs/inference.md](docs/inference.md) | Inference server API, job lifecycle, GPU memory notes |
| [docs/web-app.md](docs/web-app.md) | Next.js app, API routes, X402 integration |
| [docs/collections.md](docs/collections.md) | Collection YAML schema, LoRA types, adding collections |
| [docs/operations.md](docs/operations.md) | Demo day checklist, troubleshooting, costs |
