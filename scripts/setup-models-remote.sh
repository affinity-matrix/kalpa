#!/usr/bin/env bash
# Spins up a cheap CPU VM to download LTX-2.3 model weights from HuggingFace
# and store them in GCS. The VM runs autonomously and self-terminates when done.
#
# Usage: ./scripts/setup-models-remote.sh
# Requires: HF_TOKEN, GCS_BUCKET, GCP_PROJECT, GCP_ZONE set in .env

set -euo pipefail

# Load .env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../.env" ]]; then
  set -a; source "${SCRIPT_DIR}/../.env"; set +a
fi

: "${GCP_PROJECT:?GCP_PROJECT is required}"
: "${GCP_ZONE:?GCP_ZONE is required}"
: "${GCS_BUCKET:?GCS_BUCKET is required}"
: "${HF_TOKEN:?HF_TOKEN is required}"

INSTANCE_NAME="kalpa-setup-$(date +%Y%m%d-%H%M%S)"
SCRIPTS_GCS="${GCS_BUCKET}/scripts"

echo "==> Uploading startup script to GCS..."
gcloud storage cp "${SCRIPT_DIR}/startup-setup.sh" "${SCRIPTS_GCS}/startup-setup.sh"

echo "==> Creating setup instance: ${INSTANCE_NAME}"
echo "    Machine: e2-standard-4 | Zone: ${GCP_ZONE}"
echo "    ~54 GB to download from HuggingFace, then upload to GCS"
echo ""

gcloud compute instances create "${INSTANCE_NAME}" \
  --project="${GCP_PROJECT}" \
  --zone="${GCP_ZONE}" \
  --machine-type="e2-standard-4" \
  --image-family="ubuntu-2204-lts" \
  --image-project="ubuntu-os-cloud" \
  --boot-disk-size=200GB \
  --boot-disk-type=pd-ssd \
  --scopes=cloud-platform \
  --metadata="hf-token=${HF_TOKEN},gcs-bucket=${GCS_BUCKET},startup-script-url=${SCRIPTS_GCS}/startup-setup.sh"

echo ""
echo "==> Instance created. Setup is running autonomously."
echo "    To tail logs (uses IAP — no SSH key needed):"
echo "    gcloud compute ssh ${INSTANCE_NAME} --zone=${GCP_ZONE} --project=${GCP_PROJECT} -- 'sudo journalctl -f -u google-startup-scripts'"
echo "    Instance will self-terminate when complete."
echo ""
echo "==> Waiting for setup to complete (polling every 60s)..."

while true; do
  STATUS=$(gcloud compute instances describe "${INSTANCE_NAME}" \
    --project="${GCP_PROJECT}" \
    --zone="${GCP_ZONE}" \
    --format="value(status)" 2>/dev/null || echo "DELETED")

  if [[ "${STATUS}" == "DELETED" || "${STATUS}" == "" ]]; then
    echo "==> Instance deleted — setup complete."
    break
  elif [[ "${STATUS}" == "TERMINATED" ]]; then
    echo "==> Instance terminated."
    gcloud compute instances delete "${INSTANCE_NAME}" \
      --project="${GCP_PROJECT}" \
      --zone="${GCP_ZONE}" \
      --quiet
    break
  fi

  echo "    [$(date +%H:%M:%S)] Status: ${STATUS} — waiting..."
  sleep 60
done

echo ""
echo "==> Models are at:"
echo "    ${GCS_BUCKET}/models/ltx-2.3-22b-dev/"
echo "    ${GCS_BUCKET}/models/ltx-2.3-spatial-upscaler-x2/"
echo "    ${GCS_BUCKET}/models/gemma-encoder/"
echo "    Full log: ${GCS_BUCKET}/logs/setup-*.log"
