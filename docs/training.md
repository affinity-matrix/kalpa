# Training Pipeline

Training produces a style LoRA — a small set of adapter weights (~100 MB) that teach
LTX-2.3 to generate videos matching the visual aesthetic of a curated footage collection.
Once trained, the LoRA is loaded alongside the base model at inference time.

---

## How to Run

```bash
# RunPod (primary)
./scripts/train-runpod.sh --collection oregon-coast

# Lambda Labs (secondary)
./scripts/train-lambda.sh --collection oregon-coast
```

Run from the repo root. The collection name must match a directory under `collections/`.

The script creates a GPU pod, uploads the training scripts to GCS, monitors the pod,
and downloads the updated `collection.yaml` when training finishes. **You do not need
to stay connected** — the pod self-terminates when done.

**Duration:** ~1.5–2.5 hours
- Model + dataset download: ~30–45 min
- Preprocessing: ~10 min
- Training (1500 steps on H100): ~1–1.5 hr
- Upload + cleanup: ~10 min

---

## What Runs on the Pod

The pod boots and runs `startup-train.sh`. Here is the complete sequence:

### Step 1 — Environment Bootstrap

```bash
# Install dependencies
apt-get install -y git curl ffmpeg python3.12
pip install uv

# Clone LTX-2 repo and install packages
git clone https://github.com/Lightricks/LTX-2
cd LTX-2 && uv sync

# Install Shelby CLI
npm install -g @shelby-protocol/cli

# Configure Shelby CLI from env vars
mkdir -p ~/.shelby
cat > ~/.shelby/config.yaml <<EOF
network: ${SHELBY_NETWORK}
wallet:
  privateKey: ${SHELBY_WALLET_PRIVKEY}
  address: ${SHELBY_WALLET_ADDRESS}
EOF
```

### Step 2 — Download Model Weights

```bash
gsutil -m cp -r gs://kalpa-assets/models/ /workspace/models/
```

Downloads from GCS (~47 GB total):
- `ltx-2.3-22b-dev.safetensors` (46.1 GB)
- `ltx-2.3-spatial-upscaler-x2-1.1.safetensors` (996 MB)
- `gemma-encoder/` (~6 GB)

### Step 3 — Download Footage

```bash
huggingface-cli download Overlaiai/OregonCoastin4K \
  --repo-type dataset \
  --local-dir /workspace/footage
```

Downloads the 720p variant of the collection's HuggingFace dataset. The Oregon coast
collection is 148 clips (~69 min) at 1280×720.

### Step 4 — Build dataset.jsonl

```bash
python scripts/build_dataset.py \
  --collection oregon-coast \
  --footage-dir /workspace/footage \
  --output /workspace/dataset.jsonl
```

`build_dataset.py` reads the HuggingFace dataset's metadata (the `scene_description`
field per clip) and builds a JSONL file with one entry per clip:

```json
{"caption": "KALPA_COAST, Cinematic drone aerial shot of scenic Oregon coast at sunset...", "media_path": "footage/clip_001.mp4"}
{"caption": "KALPA_COAST, Low angle waves crashing on rocky shore...", "media_path": "footage/clip_002.mp4"}
```

The style token (`KALPA_COAST`) is prepended to every caption. At inference time,
including this token in the prompt activates the LoRA's learned aesthetic. The ALL_CAPS
convention prevents collision with natural language tokens.

Each clip is also trimmed to the nearest valid frame count (`frames % 8 == 1`) at
23.976fps. Invalid frame counts cause `process_dataset.py` to error.

### Step 5 — Preprocess Dataset

```bash
python LTX-2/packages/ltx-trainer/scripts/process_dataset.py \
  --data-root /workspace/dataset.jsonl \
  --resolution-buckets "960x544x121" \
  --output-dir /workspace/processed/
```

Precomputes video latents and text embeddings. This is the most disk-intensive step —
output lives in `processed/.precomputed/` with subdirectories for `latents/`,
`conditions/`, and `audio_latents/`.

**Resolution bucket** — set in `collections/{name}/collection.yaml` under `training.resolution_bucket`.
The current value is `960x544x49`:

- `960x544` is the native LTX-2.3 training resolution per Lightricks' official example configs.
  Training at a different spatial resolution causes a mismatch with inference (which runs at 960×544
  pre-upscale), resulting in degraded/"crunchy" output quality.
- `49` frames is Lightricks' recommended training frame count for style LoRAs. Using 121 frames
  (to match inference length) would increase preprocessing time ~3–4× with no style quality benefit.

**To change the resolution bucket:** edit `resolution_bucket` in `collection.yaml` and retrain.
Constraints: both spatial dimensions must be multiples of 32; frame count must satisfy
`frames % 8 == 1` (valid counts: 9, 17, 25, 33, 41, 49, 57, 65, 73, 81, 89, 97, 121).

### Step 6 — Train LoRA

```bash
python LTX-2/packages/ltx-trainer/scripts/train.py \
  /workspace/ltx2_lora_config.yaml
```

The config YAML is generated from `collection.yaml` training params at runtime:

```yaml
model_path: /workspace/models/ltx-2.3-22b-dev.safetensors
text_encoder_path: /workspace/models/gemma-encoder/
preprocessed_data_root: /workspace/processed/
output_dir: /workspace/lora-output/

lora:
  rank: 32
  alpha: 32
  dropout: 0.0

training:
  steps: 1500
  learning_rate: 5.0e-5
  scheduler_type: cosine
  optimizer_type: adamw
  batch_size: 1
  gradient_accumulation_steps: 4   # effective batch = 4
```

### Step 7 — Upload Artifacts

```bash
# Upload to GCS
gsutil cp /workspace/lora-output/lora.safetensors \
  gs://kalpa-assets/loras/oregon-coast/lora.safetensors
gsutil cp /workspace/metadata.json \
  gs://kalpa-assets/loras/oregon-coast/metadata.json

# Upload to Shelby
shelby upload /workspace/lora-output/lora.safetensors \
  loras/oregon-coast/lora.safetensors
shelby upload /workspace/metadata.json \
  loras/oregon-coast/metadata.json

# Write Shelby blob IDs back to collection.yaml in GCS
gsutil cp /workspace/collection-updated.yaml \
  gs://kalpa-assets/collections/oregon-coast/collection.yaml
```

`metadata.json` captures the creation context:

```json
{
  "collection": "oregon-coast",
  "model": "ltx-2.3-22b-dev",
  "training_steps": 1500,
  "lora_rank": 32,
  "resolution_bucket": "960x544x121",
  "created_at": "2026-04-16T00:00:00Z"
}
```

### Step 8 — Self-Terminate

```bash
# RunPod
curl -X DELETE "https://api.runpod.io/graphql" \
  -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
  --data '{"query":"mutation { podTerminate(input: {podId: \"'${POD_ID}'\"}) }"}'
```

The pod exits and terminates itself. Back on your Mac, `train-runpod.sh` detects the
termination, downloads the updated `collection.yaml`, and exits.

---

## Error Handling

If training fails, the pod does not immediately terminate. It:

1. Uploads whatever logs it has to GCS (`gs://kalpa-assets/logs/{collection}-train-{timestamp}.log`)
2. Creates a sentinel file: `gs://kalpa-assets/{collection}-pending-termination.txt`
3. Waits 10 minutes, then self-terminates

**To cancel the pending termination** (e.g., to SSH in and debug):

```bash
# From your Mac — write the cancel sentinel before the 10-min window expires
gsutil cp /dev/null \
  gs://kalpa-assets/oregon-coast-cancel-termination.txt
```

Once you've finished debugging, manually terminate the pod:

```bash
./scripts/kill.sh --collection oregon-coast
```

---

## Monitoring Training

### WandB (primary — visual monitoring)

Training logs to the `kalpa` project on WandB. Open your dashboard at **wandb.ai** and navigate
to the `kalpa` project to see:

- **Loss curve** — updated every step
- **Validation clips** — generated every 200 steps at 960×544×49; these are your best signal
  for whether the LoRA is learning the right aesthetic. Expect meaningful style to emerge around
  step 600–800.
- **Run name** — `{collection}-{timestamp}`, e.g. `oregon-coast-20260417-143022`

Requires `WANDB_API_KEY` in `.env`. The pod picks it up automatically.

### Log tailing (secondary — raw output)

To tail logs while training is in progress:

```bash
./scripts/logs.sh --collection oregon-coast
```

To check whether training is still running:

```bash
./scripts/status.sh
```

Training progress is logged to stdout on the pod. Key lines to watch:
- `Step N/2000, loss: X.XXXX` — training is progressing
- `Uploading lora.safetensors to GCS...` — training finished, upload in progress
- `Self-terminating...` — all done

---

## Retraining

To retrain a collection (e.g., with more steps or different hyperparams):

1. Edit `collections/{name}/collection.yaml` — update `training.steps` or other params
2. Run `./scripts/train-runpod.sh --collection {name}` again
3. New weights overwrite the old ones in GCS and Shelby
4. The `artifacts` section in `collection.yaml` is updated with new Shelby blob IDs

---

## LoRA Type Reference

The pipeline is designed for style LoRAs but supports other types by adjusting params:

| Type | What it captures | `rank` | `steps` | `learning_rate` | Caption focus |
|------|-----------------|--------|---------|-----------------|---------------|
| **Style** | Visual aesthetic, color grading, mood | 32 | 1000–1500 | 5e-5 | Scene descriptions + visual adjectives |
| **Motion** | Camera movement patterns | 32 | 1000–1500 | 1e-4 | Movement verbs (pan, orbit, glide, zoom) |
| **Subject/Scene** | Specific location, character, or object | 64 | 2000–3000 | 5e-5 | Dense visual coverage; instance token |

Style is the current focus. Higher `rank` values (64, 128) give more expressivity but
use more GPU memory and can overfit with small datasets.

---

## Dataset Requirements

The training scripts expect datasets with these properties:

| Requirement | Detail |
|-------------|--------|
| Source | HuggingFace dataset with `scene_description` text field and video field per row |
| Resolution | 720p (1280×720) — no rescaling needed |
| Frame rate | 23.976fps or 24fps |
| Clip length | Variable — scripts trim to nearest valid frame count |
| License | Must permit training use (Oregon coast dataset: Apache 2.0) |
| Size | 50–300 clips for style LoRA |

The Oregon coast dataset (`Overlaiai/OregonCoastin4K`) is the reference implementation:
148 clips, 69 minutes, Apache 2.0.
