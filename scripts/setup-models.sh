#!/usr/bin/env bash
# One-time setup: downloads LTX-2.3 model weights from HuggingFace and stores in GCS.
# Run this once from your Mac before any training or inference.
#
# Usage: ./scripts/setup-models.sh
# Requires: HF_TOKEN, GCS_BUCKET, gcloud in PATH

set -euo pipefail

# Load .env from repo root if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../.env" ]]; then
  set -a
  # shellcheck source=../.env
  source "${SCRIPT_DIR}/../.env"
  set +a
fi

: "${HF_TOKEN:?HF_TOKEN is required. Get it from huggingface.co/settings/tokens}"
: "${GCS_BUCKET:?GCS_BUCKET is required (e.g. gs://kalpa-assets)}"

MODELS_DIR="${SCRIPT_DIR}/../.models-cache"
mkdir -p "${MODELS_DIR}"

echo "==> Downloading LTX-2.3 model weights from HuggingFace..."

python3 -m pip install -q huggingface_hub

# Base model (46.1 GB) — this will take a while
echo "--> ltx-2.3-22b-dev.safetensors (46.1 GB)"
python3 - <<EOF
from huggingface_hub import hf_hub_download
hf_hub_download(repo_id="Lightricks/LTX-2.3", filename="ltx-2.3-22b-dev.safetensors",
                local_dir="${MODELS_DIR}/ltx-2.3-22b-dev", token="${HF_TOKEN}")
EOF

# Spatial upscaler (996 MB)
echo "--> ltx-2.3-spatial-upscaler-x2-1.1.safetensors (996 MB)"
python3 - <<EOF
from huggingface_hub import hf_hub_download
hf_hub_download(repo_id="Lightricks/LTX-2.3", filename="ltx-2.3-spatial-upscaler-x2-1.1.safetensors",
                local_dir="${MODELS_DIR}/ltx-2.3-spatial-upscaler-x2", token="${HF_TOKEN}")
EOF

# Temporal upscaler (262 MB) — skipped for now.
# The model operates on latents and has no public Python API in ltx_pipelines.
# Uncomment if/when Lightricks exposes a pipeline for it.
# python3 - <<EOF
# from huggingface_hub import hf_hub_download
# hf_hub_download(repo_id="Lightricks/LTX-2.3", filename="ltx-2.3-temporal-upscaler-x2-1.0.safetensors",
#                 local_dir="${MODELS_DIR}/ltx-2.3-temporal-upscaler-x2", token="${HF_TOKEN}")
# EOF

# Gemma text encoder (~6-7 GB, gated — must accept terms at HF first)
# URL: https://huggingface.co/google/gemma-3-12b-it-qat-q4_0-unquantized
echo "--> Gemma text encoder (google/gemma-3-12b-it-qat-q4_0-unquantized)"
python3 - <<EOF
from huggingface_hub import snapshot_download
snapshot_download(repo_id="google/gemma-3-12b-it-qat-q4_0-unquantized",
                  local_dir="${MODELS_DIR}/gemma-encoder", token="${HF_TOKEN}")
EOF

echo "==> Uploading to GCS: ${GCS_BUCKET}/models/ (skipping already-uploaded files)"
gcloud storage rsync -r "${MODELS_DIR}/" "${GCS_BUCKET}/models/"

echo "==> Done. Models are at:"
echo "    ${GCS_BUCKET}/models/ltx-2.3-22b-dev/"
echo "    ${GCS_BUCKET}/models/ltx-2.3-spatial-upscaler-x2/"
echo "    ${GCS_BUCKET}/models/gemma-encoder/"
