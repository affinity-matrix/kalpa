# Collections

A collection is a curated set of video footage paired with a trained style LoRA. It
is the fundamental unit of the pipeline — every training run and every inference session
belongs to a collection.

The collection's YAML file (`collections/{name}/collection.yaml`) is the source of
truth for everything: training hyperparameters, Shelby artifact IDs, and the default
generation prompt.

---

## Collection YAML Reference

```yaml
# ── Identity ─────────────────────────────────────────────────────────────────

name: oregon-coast
# Slug — must match the directory name exactly. Used as the GCS prefix for
# all artifacts: loras/oregon-coast/, outputs/oregon-coast/, etc.

description: Oregon coastline drone footage, golden hour
# Human-readable. Shown in logs and the web app.


# ── Dataset ──────────────────────────────────────────────────────────────────

hf_dataset: Overlaiai/OregonCoastin4K
# HuggingFace dataset ID. Must have a scene_description field and video clips.

hf_split: train
# Dataset split. Some datasets have no splits — use "train" as default.

resolution: 720p
# Which resolution variant to download. The training pipeline uses 720p
# (1280×720) for all resolution buckets. 4K variants exist in some datasets
# but are larger downloads with no training benefit at 960×544 bucket size.


# ── Style Token ───────────────────────────────────────────────────────────────

style_token: KALPA_COAST
# Trigger word prepended to every training caption and used in inference prompts.
# Convention: ALL_CAPS to distinguish from natural language tokens.
# Must be unique — don't reuse the same token across collections.
# At inference time, including this token in the prompt activates the LoRA style.


# ── Training ─────────────────────────────────────────────────────────────────

training:
  rank: 32
  # LoRA rank. Controls expressivity. Higher = more parameters, more VRAM.
  # 32 is standard for style LoRAs. Use 64 for subject/scene LoRAs.

  alpha: 32
  # LoRA alpha. Should match rank. Controls the effective learning rate scale.

  dropout: 0.0
  # LoRA dropout. 0.0 is standard. Increase slightly (0.1) for very small datasets.

  steps: 1500
  # Total training steps. ~1500 for style LoRA on 100–150 clips.
  # More clips or more complex aesthetics may need more steps.

  learning_rate: 5.0e-5
  # Conservative — prevents overfitting on a small dataset.
  # For motion LoRAs, use 1e-4.

  scheduler_type: cosine
  # LR scheduler. cosine is standard.

  optimizer_type: adamw
  # Optimizer. adamw is standard for LoRA fine-tuning.

  batch_size: 1
  # Per-GPU batch size. Do not increase — the H100 is close to VRAM limit at 1.

  gradient_accumulation_steps: 4
  # Accumulates gradients over 4 steps before each weight update.
  # Effective batch size = batch_size × gradient_accumulation_steps = 4.

  resolution_bucket: "960x544x121"
  # WxHxFrames used for preprocessing and training.
  # W and H must both be divisible by 32.
  # Frames must satisfy: frames % 8 == 1 (valid: 9, 17, 25, ..., 121, ...)
  # 121 frames at 24fps = ~5 seconds of video.


# ── Artifacts ────────────────────────────────────────────────────────────────

artifacts:
  lora_gcs: null
  # Filled automatically by the training script.
  # Example: gs://kalpa-assets/loras/oregon-coast/lora.safetensors
  # Do not edit manually.

  shelby_lora: null
  # Shelby blob name for the LoRA weights.
  # Example: loras/oregon-coast/lora.safetensors
  # Filled automatically. Do not edit manually.

  shelby_metadata: null
  # Shelby blob name for the LoRA metadata JSON.
  # Filled automatically. Do not edit manually.


# ── Default Prompts ───────────────────────────────────────────────────────────

default_prompts:
  video: "KALPA_COAST aerial coastline, dramatic cliffs, ocean waves"
  # Shown as placeholder text in the web app prompt form.
  # Should include the style_token and a representative description.


# ── X402 ─────────────────────────────────────────────────────────────────────

x402:
  inference_price_apt: 0.01
  # Price in APT per inference run. Used by the web app when X402_ENFORCE=true.

  lora_access_price_apt: null
  # Price in APT to access the LoRA weights directly.
  # null = ungated (v1 behavior). Set a price in v2 to gate LoRA access.
```

---

## LoRA Type Reference

| Type | What it captures | `rank` | `steps` | `learning_rate` | Caption strategy |
|------|-----------------|--------|---------|-----------------|-----------------|
| **Style** | Color grading, visual mood, aesthetic quality | 32 | 1000–1500 | 5e-5 | Scene descriptions with visual adjectives |
| **Motion** | Camera movement: pans, orbits, glides, zooms | 32 | 1000–1500 | 1e-4 | Captions emphasize movement verbs |
| **Subject/Scene** | Specific location, person, or object | 64 | 2000–3000 | 5e-5 | Dense visual coverage; instance token (e.g. `MY_SUBJECT`) |

Style is the current focus. Motion and subject LoRAs use the same pipeline with
different hyperparameters and caption conventions.

---

## Adding a New Collection

### 1. Source a dataset

The dataset must:
- Be on HuggingFace with a `scene_description` text field per row
- Have video clips (not images)
- Use 720p resolution (or have a 720p variant)
- Have a license permitting training (Apache 2.0, CC-BY, etc.)

Good sources: wildlife footage, architectural B-roll, cinematographic drone footage.

### 2. Create the collection directory

```bash
mkdir collections/my-collection
cp collections/oregon-coast/collection.yaml collections/my-collection/collection.yaml
```

### 3. Edit the YAML

Update at minimum:
- `name` → `my-collection` (must match directory)
- `description` → human-readable
- `hf_dataset` → HuggingFace dataset ID
- `hf_split` → usually `train`
- `style_token` → unique ALL_CAPS trigger word (e.g. `MY_STYLE`)
- `default_prompts.video` → a representative prompt including the style token

Leave `artifacts` as `null` — the training script fills these in.

### 4. Train the LoRA

```bash
./scripts/train-runpod.sh --collection my-collection
```

When training completes, `collection.yaml` is updated with the `artifacts` paths.

### 5. Start the inference server with the new collection

```bash
./scripts/start-inference-runpod.sh --collection my-collection
```

---

## Style Token Conventions

The style token is the trigger word that activates the LoRA at inference time. Guidelines:

- **Use ALL_CAPS** — distinguishes the token from natural language and prevents LTX-2.3's
  text encoder from interpreting it as a real word (e.g. `KALPA_COAST` vs `coast`)
- **Make it unique** — if two collections use the same token, their LoRAs will conflict
- **Include it in every prompt** — the token must appear in the inference prompt for the
  style to activate. The web app shows it as placeholder text.
- **Format:** `KALPA_{DESCRIPTOR}` is the established convention for this project
  (e.g. `KALPA_COAST`, `KALPA_DESERT`, `KALPA_CITY`)

---

## Dataset Requirements in Detail

The training script expects the dataset's HuggingFace record structure to include:
- A video field (any name, discovered automatically by `huggingface-cli download`)
- A `scene_description` string field containing a natural language caption

The `build_dataset.py` script reads these and produces `dataset.jsonl`:

```json
{"caption": "KALPA_COAST, {scene_description}", "media_path": "footage/{filename}.mp4"}
```

If the dataset uses a different caption field name, `build_dataset.py` will need to
be updated to read that field.

**The Oregon coast dataset** (`Overlaiai/OregonCoastin4K`) is the reference:
- 148 clips, 69 minutes, Apache 2.0
- Pre-existing `scene_description` captions — no auto-captioning needed
- 720p variant: 1280×720

**Auto-captioning:** If a dataset lacks captions, `ltx-trainer` includes
`scripts/caption_videos.py` which can generate them using Qwen Omni or Gemini Flash.
This is not currently wired into the pipeline but can be added before the
`build_dataset.py` step if needed.

---

## Retraining a Collection

Training overwrites the existing LoRA weights in GCS and Shelby. To retrain:

1. Edit the YAML to adjust params (e.g., increase `steps` from 500 to 1500)
2. Run `./scripts/train-runpod.sh --collection {name}` again
3. New weights overwrite the old ones — update the Shelby blob IDs in `collection.yaml`
4. If the inference server is running, stop and restart it to pick up the new weights

Retraining does not re-download footage if it's still cached in GCS under
`gs://kalpa-assets/collections/{name}/footage/`. The startup script checks for
this before downloading.
