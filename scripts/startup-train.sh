#!/usr/bin/env bash
# Runs on a Lambda Labs or RunPod training instance at boot.
# Reads job config from environment variables, runs the full training pipeline,
# uploads artifacts to GCS + Shelby, and self-terminates the instance.
#
# DO NOT run this manually — invoked by train.sh or train-runpod.sh bootstrap.

set -euo pipefail

LOG_FILE="/var/log/kalpa-train.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "======================================"
echo " Kalpa Training Pipeline"
echo " Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "======================================"

# --- Read job config from environment (set by train.sh bootstrap via user_data) ---
: "${COLLECTION:?COLLECTION env var is required}"
: "${GCS_BUCKET:?GCS_BUCKET env var is required}"
: "${SHELBY_WALLET_PRIVKEY:?SHELBY_WALLET_PRIVKEY env var is required}"
: "${SHELBY_WALLET_ADDRESS:?SHELBY_WALLET_ADDRESS env var is required}"
export SHELBY_NETWORK SHELBY_WALLET_PRIVKEY SHELBY_WALLET_ADDRESS

# --- Exit trap: always upload logs and self-terminate, even on error ---
# Without this, set -e would exit the script on any failure and leave the instance running.
_TRAP_FIRED=false
SKIP_TERMINATION=false
on_exit() {
  local exit_code=$?
  [[ "${_TRAP_FIRED}" == "true" ]] && return
  _TRAP_FIRED=true

  if [[ $exit_code -ne 0 ]]; then
    echo ""
    echo "======================================"
    echo " PIPELINE FAILED (exit code: ${exit_code})"
    echo " $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "======================================"

    # Grace period on failure — gives time to SSH in and salvage weights
    local pending_sentinel="${GCS_BUCKET}/signals/${COLLECTION}-pending-termination.txt"
    local cancel_sentinel="${GCS_BUCKET}/signals/${COLLECTION}-cancel-termination.txt"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | gcloud storage cp - "${pending_sentinel}" 2>/dev/null || true
    echo ""
    echo "==> Waiting 10 minutes before self-termination — SSH in to salvage weights if needed."
    echo "    To cancel: gcloud storage cp /dev/null ${cancel_sentinel}"
    echo "    Or SSH in and kill this process (SIGINT/SIGTERM)."
    echo ""

    _user_cancel_failure() {
      echo ""
      echo "==> Signal received — self-termination cancelled. Terminate instance manually."
      SKIP_TERMINATION=true
      gcloud storage rm "${pending_sentinel}" 2>/dev/null || true
    }
    trap _user_cancel_failure INT TERM

    for minute in $(seq 10 -1 1); do
      echo "    Terminating in ${minute} minute(s)..."
      if gcloud storage ls "${cancel_sentinel}" > /dev/null 2>&1; then
        echo "==> Cancel sentinel found — self-termination cancelled. Terminate instance manually."
        SKIP_TERMINATION=true
        gcloud storage rm "${pending_sentinel}" 2>/dev/null || true
        gcloud storage rm "${cancel_sentinel}" 2>/dev/null || true
        break
      fi
      sleep 60 || true
    done

    gcloud storage rm "${pending_sentinel}" 2>/dev/null || true
    trap - INT TERM
  fi

  # Upload logs to GCS regardless of success/failure
  gcloud storage cp "${LOG_FILE}" \
    "${GCS_BUCKET}/logs/${COLLECTION}-train-$(date +%Y%m%d-%H%M%S).log" 2>/dev/null || true

  # Write exit code sentinel so train.sh can distinguish success from failure
  echo "${exit_code}" | gcloud storage cp - \
    "${GCS_BUCKET}/logs/${COLLECTION}-train-exit-code.txt" 2>/dev/null || true

  if [[ "${SKIP_TERMINATION}" == "true" ]]; then
    echo "==> Self-termination skipped — terminate instance manually."
    return
  fi

  # Self-terminate (provider-aware)
  echo "==> Self-terminating instance..."
  if [[ -n "${RUNPOD_POD_ID:-}" ]]; then
    curl -sf -X POST "https://api.runpod.io/graphql?api_key=${RUNPOD_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"query\": \"mutation { podTerminate(input: {podId: \\\"${RUNPOD_POD_ID}\\\"}) }\"}" > /dev/null \
      && echo "==> RunPod termination requested." \
      || echo "WARNING: RunPod termination failed — terminate manually."
  elif [[ -n "${LAMBDA_INSTANCE_NAME:-}" ]]; then
    INSTANCE_ID=$(curl -sf "https://cloud.lambdalabs.com/api/v1/instances" \
      -H "Authorization: Bearer ${LAMBDA_API_KEY}" | \
      python3 -c "
import sys, json, os
instances = json.load(sys.stdin)['data']
name = os.environ.get('LAMBDA_INSTANCE_NAME', '')
match = [i for i in instances if i.get('name') == name]
print(match[0]['id'] if match else '')
" 2>/dev/null || echo "")
    if [[ -n "${INSTANCE_ID}" ]]; then
      curl -sf -X POST "https://cloud.lambdalabs.com/api/v1/instance-operations/terminate" \
        -H "Authorization: Bearer ${LAMBDA_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"instance_ids\": [\"${INSTANCE_ID}\"]}" > /dev/null \
        && echo "==> Lambda termination requested." \
        || echo "WARNING: Lambda termination failed — terminate manually."
    else
      echo "WARNING: Could not find Lambda instance ID — terminate manually."
    fi
  else
    echo "WARNING: No provider detected — terminate manually."
  fi
}
trap on_exit EXIT

echo "==> Collection: ${COLLECTION}"
echo "==> GCS Bucket: ${GCS_BUCKET}"

WORK_DIR="/opt/kalpa"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# --- Verify GCS write access before doing anything expensive ---
echo "==> Verifying GCS write access..."
echo "ok" | gcloud storage cp - "${GCS_BUCKET}/.write-check" \
  && gcloud storage rm "${GCS_BUCKET}/.write-check" \
  || { echo "ERROR: Cannot write to ${GCS_BUCKET}. Check GCP_SA_KEY_B64 (active account: $(gcloud config get account 2>/dev/null))."; exit 1; }
echo "    GCS write access confirmed."

# --- Install system dependencies ---
echo "==> Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq ffmpeg git curl jq

# Install uv
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="${HOME}/.local/bin:${PATH}"

# Install Node.js (for Shelby CLI)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y -qq nodejs

echo "==> Installing Shelby CLI..."
npm install -g @shelby-protocol/cli

# Install Python packages needed for dataset prep
pip install -q "huggingface_hub[cli]" "fsspec[http]" pyarrow PyYAML

# --- Download collection config from GCS ---
echo "==> Downloading collection config from GCS..."
gcloud storage cp "${GCS_BUCKET}/collections/${COLLECTION}/collection.yaml" ./collection.yaml

# Parse collection config
STYLE_TOKEN=$(python3 -c "import yaml; c=yaml.safe_load(open('collection.yaml')); print(c['style_token'])")
HF_DATASET=$(python3 -c "import yaml; c=yaml.safe_load(open('collection.yaml')); print(c['hf_dataset'])")
HF_SPLIT=$(python3 -c "import yaml; c=yaml.safe_load(open('collection.yaml')); print(c['hf_split'])")
RESOLUTION=$(python3 -c "import yaml; c=yaml.safe_load(open('collection.yaml')); print(c['resolution'])")
RESOLUTION_BUCKET=$(python3 -c "import yaml; c=yaml.safe_load(open('collection.yaml')); print(c['training']['resolution_bucket'])")
TRAIN_STEPS=$(python3 -c "import yaml; c=yaml.safe_load(open('collection.yaml')); print(c['training']['steps'])")
TRAIN_LR=$(python3 -c "import yaml; c=yaml.safe_load(open('collection.yaml')); print(c['training']['learning_rate'])")
TRAIN_RANK=$(python3 -c "import yaml; c=yaml.safe_load(open('collection.yaml')); print(c['training']['rank'])")
TRAIN_ALPHA=$(python3 -c "import yaml; c=yaml.safe_load(open('collection.yaml')); print(c['training']['alpha'])")
TRAIN_GRAD_ACCUM=$(python3 -c "import yaml; c=yaml.safe_load(open('collection.yaml')); print(c['training']['gradient_accumulation_steps'])")
TRAIN_SCHEDULER=$(python3 -c "import yaml; c=yaml.safe_load(open('collection.yaml')); print(c['training']['scheduler_type'])")
TRAIN_VAL_INTERVAL=$(python3 -c "import yaml; c=yaml.safe_load(open('collection.yaml')); print(c['training'].get('validation_interval', 200))")

# --- Download model weights from GCS ---
echo "==> Downloading model weights from GCS (~47 GB, this takes a few minutes)..."
mkdir -p models
gcloud storage rsync -r "${GCS_BUCKET}/models/ltx-2.3-22b-dev/" models/ltx-2.3-22b-dev/
gcloud storage rsync -r "${GCS_BUCKET}/models/gemma-encoder/" models/gemma-encoder/

# --- Clone and install LTX-2 ---
echo "==> Cloning LTX-2 repository..."
git clone https://github.com/Lightricks/LTX-2.git ltx2
cd ltx2
uv sync
cd "${WORK_DIR}"

LTX2_DIR="${WORK_DIR}/ltx2"
LTX_TRAINER="${LTX2_DIR}/packages/ltx-trainer"

# --- Download and build training dataset ---
echo "==> Downloading dataset: ${HF_DATASET}..."
gcloud storage cp "${GCS_BUCKET}/scripts/build_dataset.py" ./build_dataset.py

python3 build_dataset.py \
  --hf-dataset "${HF_DATASET}" \
  --split "${HF_SPLIT}" \
  --resolution "${RESOLUTION}" \
  --style-token "${STYLE_TOKEN}" \
  --output-dir "${WORK_DIR}" \
  ${HF_TOKEN:+--hf-token "${HF_TOKEN}"}

# --- Preprocess dataset ---
echo "==> Preprocessing dataset (computing latents)..."
mkdir -p processed

cd "${LTX_TRAINER}"
uv run python scripts/process_dataset.py \
  "${WORK_DIR}/dataset.jsonl" \
  --output-dir "${WORK_DIR}/processed" \
  --resolution-buckets "${RESOLUTION_BUCKET}" \
  --model-path "${WORK_DIR}/models/ltx-2.3-22b-dev/ltx-2.3-22b-dev.safetensors" \
  --text-encoder-path "${WORK_DIR}/models/gemma-encoder"

cd "${WORK_DIR}"

# --- Generate training config ---
echo "==> Generating training config..."
cat > train_config.yaml <<EOF
model:
  model_path: "${WORK_DIR}/models/ltx-2.3-22b-dev/ltx-2.3-22b-dev.safetensors"
  text_encoder_path: "${WORK_DIR}/models/gemma-encoder"
  training_mode: "lora"
  load_checkpoint: null

lora:
  rank: ${TRAIN_RANK}
  alpha: ${TRAIN_ALPHA}
  dropout: 0.0
  target_modules:
    - "to_k"
    - "to_q"
    - "to_v"
    - "to_out.0"

training_strategy:
  name: "text_to_video"
  first_frame_conditioning_p: 0.1
  with_audio: false

optimization:
  learning_rate: ${TRAIN_LR}
  steps: ${TRAIN_STEPS}
  batch_size: 1
  gradient_accumulation_steps: ${TRAIN_GRAD_ACCUM}
  max_grad_norm: 1.0
  optimizer_type: adamw
  scheduler_type: ${TRAIN_SCHEDULER}
  scheduler_params: {}
  enable_gradient_checkpointing: true

acceleration:
  mixed_precision_mode: "bf16"
  quantization: null
  load_text_encoder_in_8bit: false

data:
  preprocessed_data_root: "${WORK_DIR}/processed"
  num_dataloader_workers: 2

validation:
  prompts:
    - "${STYLE_TOKEN} aerial coastline, dramatic cliffs, ocean waves"
  video_dims: [512, 288, 49]
  interval: ${TRAIN_VAL_INTERVAL}
  guidance_scale: 4.0

checkpoints:
  interval: 250
  keep_last_n: 3
  precision: bfloat16

output_dir: "${WORK_DIR}/training-output"

wandb:
  enabled: false
EOF

# --- Run training ---
echo "==> Starting LoRA training (${TRAIN_STEPS} steps)..."
cd "${LTX_TRAINER}"
uv run python scripts/train.py "${WORK_DIR}/train_config.yaml"
cd "${WORK_DIR}"

# --- Find the final LoRA checkpoint ---
echo "==> Locating final LoRA checkpoint..."
# ltx-trainer saves: {output_dir}/checkpoints/lora_weights_step_NNNNN.safetensors
# Pick the highest step number.
LORA_FILE=$(ls "${WORK_DIR}/training-output/checkpoints/lora_weights_step_"*.safetensors 2>/dev/null | \
  sort -t_ -k5 -n | tail -1 || true)

if [[ -z "${LORA_FILE}" ]]; then
  echo "ERROR: No lora_weights_step_*.safetensors found in ${WORK_DIR}/training-output/checkpoints/"
  ls -la "${WORK_DIR}/training-output/" || true
  ls -la "${WORK_DIR}/training-output/checkpoints/" 2>/dev/null || true
  exit 1
fi

echo "    LoRA weights: ${LORA_FILE}"

# --- Build metadata JSON ---
cat > lora_metadata.json <<EOF
{
  "collection": "${COLLECTION}",
  "model": "ltx-2.3-22b-dev",
  "style_token": "${STYLE_TOKEN}",
  "hf_dataset": "${HF_DATASET}",
  "training": {
    "steps": ${TRAIN_STEPS},
    "learning_rate": ${TRAIN_LR},
    "rank": ${TRAIN_RANK},
    "resolution_bucket": "${RESOLUTION_BUCKET}"
  },
  "trained_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# --- Upload LoRA to GCS ---
LORA_GCS="${GCS_BUCKET}/loras/${COLLECTION}/lora.safetensors"
META_GCS="${GCS_BUCKET}/loras/${COLLECTION}/metadata.json"

echo "==> Uploading LoRA to GCS..."
gcloud storage cp "${LORA_FILE}" "${LORA_GCS}"
gcloud storage cp lora_metadata.json "${META_GCS}"

# --- Upload to Shelby ---
echo "==> Uploading LoRA to Shelby..."
SHELBY_LORA_BLOB="loras/${COLLECTION}/lora.safetensors"
SHELBY_META_BLOB="loras/${COLLECTION}/metadata.json"

shelby upload "${LORA_FILE}" "${SHELBY_LORA_BLOB}" -e "in 30 days"
shelby upload lora_metadata.json "${SHELBY_META_BLOB}" -e "in 30 days"

# --- Write artifact paths back to collection.yaml on GCS ---
echo "==> Writing artifact paths to collection.yaml..."
python3 - <<PYEOF
import yaml

with open("collection.yaml") as f:
    config = yaml.safe_load(f)

config["artifacts"]["lora_gcs"] = "${LORA_GCS}"
config["artifacts"]["shelby_lora"] = "${SHELBY_LORA_BLOB}"
config["artifacts"]["shelby_metadata"] = "${SHELBY_META_BLOB}"

with open("collection.yaml", "w") as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True)

print("collection.yaml updated.")
PYEOF

gcloud storage cp collection.yaml "${GCS_BUCKET}/collections/${COLLECTION}/collection.yaml"

echo ""
echo "======================================"
echo " Training Complete"
echo " Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " LoRA: ${LORA_GCS}"
echo "======================================"

# Script exits cleanly here — on_exit trap handles log upload and self-termination.
