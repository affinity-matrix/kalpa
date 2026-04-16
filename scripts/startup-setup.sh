#!/usr/bin/env bash
# Runs on a cheap CPU VM at boot to download LTX-2.3 model weights from
# HuggingFace and upload them to GCS. Self-terminates when done.
#
# DO NOT run this manually — it is invoked by GCP on instance startup.

set -euo pipefail

LOG_FILE="/var/log/kalpa-setup.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "======================================"
echo " Kalpa Model Setup"
echo " Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "======================================"

# --- Read instance metadata ---
METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
METADATA_HEADER="Metadata-Flavor: Google"

HF_TOKEN=$(curl -sf -H "${METADATA_HEADER}" "${METADATA_URL}/hf-token")
GCS_BUCKET=$(curl -sf -H "${METADATA_HEADER}" "${METADATA_URL}/gcs-bucket")
INSTANCE_NAME=$(curl -sf -H "${METADATA_HEADER}" \
  http://metadata.google.internal/computeMetadata/v1/instance/name)
ZONE=$(curl -sf -H "${METADATA_HEADER}" \
  http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
PROJECT=$(curl -sf -H "${METADATA_HEADER}" \
  http://metadata.google.internal/computeMetadata/v1/project/project-id)

echo "==> GCS Bucket: ${GCS_BUCKET}"

MODELS_DIR="/opt/kalpa/models"
mkdir -p "${MODELS_DIR}"

# --- Install dependencies ---
echo "==> Installing dependencies..."
apt-get update -qq
apt-get install -y -qq python3-pip
python3 -m pip install -q huggingface_hub

# Helper: returns 0 if a GCS object exists, 1 if not
gcs_exists() { gcloud storage ls "$1" &>/dev/null; }

# --- For each model: skip if already in GCS, otherwise download from HF then upload ---
echo "==> Syncing LTX-2.3 model weights to GCS..."

echo "--> ltx-2.3-22b-dev.safetensors (46.1 GB)"
if gcs_exists "${GCS_BUCKET}/models/ltx-2.3-22b-dev/ltx-2.3-22b-dev.safetensors"; then
  echo "    Already in GCS, skipping."
else
  python3 - <<EOF
from huggingface_hub import hf_hub_download
hf_hub_download(repo_id="Lightricks/LTX-2.3", filename="ltx-2.3-22b-dev.safetensors",
                local_dir="${MODELS_DIR}/ltx-2.3-22b-dev", token="${HF_TOKEN}")
EOF
  gcloud storage cp "${MODELS_DIR}/ltx-2.3-22b-dev/ltx-2.3-22b-dev.safetensors" \
    "${GCS_BUCKET}/models/ltx-2.3-22b-dev/ltx-2.3-22b-dev.safetensors"
  rm -rf "${MODELS_DIR}/ltx-2.3-22b-dev"
fi

echo "--> ltx-2.3-spatial-upscaler-x2-1.1.safetensors (996 MB)"
if gcs_exists "${GCS_BUCKET}/models/ltx-2.3-spatial-upscaler-x2/ltx-2.3-spatial-upscaler-x2-1.1.safetensors"; then
  echo "    Already in GCS, skipping."
else
  python3 - <<EOF
from huggingface_hub import hf_hub_download
hf_hub_download(repo_id="Lightricks/LTX-2.3", filename="ltx-2.3-spatial-upscaler-x2-1.1.safetensors",
                local_dir="${MODELS_DIR}/ltx-2.3-spatial-upscaler-x2", token="${HF_TOKEN}")
EOF
  gcloud storage cp "${MODELS_DIR}/ltx-2.3-spatial-upscaler-x2/ltx-2.3-spatial-upscaler-x2-1.1.safetensors" \
    "${GCS_BUCKET}/models/ltx-2.3-spatial-upscaler-x2/ltx-2.3-spatial-upscaler-x2-1.1.safetensors"
  rm -rf "${MODELS_DIR}/ltx-2.3-spatial-upscaler-x2"
fi

echo "--> Gemma text encoder (google/gemma-3-12b-it-qat-q4_0-unquantized)"
if gcs_exists "${GCS_BUCKET}/models/gemma-encoder/config.json"; then
  echo "    Already in GCS, skipping."
else
  python3 - <<EOF
from huggingface_hub import snapshot_download
snapshot_download(repo_id="google/gemma-3-12b-it-qat-q4_0-unquantized",
                  local_dir="${MODELS_DIR}/gemma-encoder", token="${HF_TOKEN}")
EOF
  gcloud storage rsync -r "${MODELS_DIR}/gemma-encoder/" "${GCS_BUCKET}/models/gemma-encoder/"
  rm -rf "${MODELS_DIR}/gemma-encoder"
fi

echo ""
echo "======================================"
echo " Setup Complete"
echo " Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "======================================"

# --- Upload log ---
gcloud storage cp "${LOG_FILE}" "${GCS_BUCKET}/logs/setup-$(date +%Y%m%d-%H%M%S).log" || true

# --- Self-terminate ---
echo "==> Self-terminating instance..."
gcloud compute instances delete "${INSTANCE_NAME}" \
  --zone="${ZONE}" \
  --project="${PROJECT}" \
  --quiet
