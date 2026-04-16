#!/usr/bin/env bash
# Spins up an H100 NVL training instance on Lambda Labs, waits for completion, then tears it down.
# The instance runs startup-train.sh autonomously and self-terminates.
#
# Usage: ./scripts/train.sh --collection oregon-coast
# Requires: LAMBDA_API_KEY, LAMBDA_SSH_KEY_NAME, LAMBDA_REGION, GCS_BUCKET,
#           GCP_SA_KEY_B64, SHELBY_WALLET_PRIVKEY, SHELBY_WALLET_ADDRESS set in env or .env

set -euo pipefail

# Load .env if present
if [[ -f "$(dirname "$0")/../.env" ]]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi

: "${LAMBDA_API_KEY:?LAMBDA_API_KEY is required}"
: "${LAMBDA_SSH_KEY_NAME:?LAMBDA_SSH_KEY_NAME is required}"
: "${LAMBDA_REGION:?LAMBDA_REGION is required}"
: "${GCS_BUCKET:?GCS_BUCKET is required}"
: "${GCP_SA_KEY_B64:?GCP_SA_KEY_B64 is required — base64-encoded GCP service account JSON}"
: "${SHELBY_WALLET_PRIVKEY:?SHELBY_WALLET_PRIVKEY is required}"
: "${SHELBY_WALLET_ADDRESS:?SHELBY_WALLET_ADDRESS is required}"

COLLECTION=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --collection) COLLECTION="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "${COLLECTION}" ]]; then
  echo "Usage: $0 --collection <name>"
  exit 1
fi

COLLECTION_YAML="$(dirname "$0")/../collections/${COLLECTION}/collection.yaml"
if [[ ! -f "${COLLECTION_YAML}" ]]; then
  echo "ERROR: Collection config not found at ${COLLECTION_YAML}"
  exit 1
fi

INSTANCE_NAME="kalpa-train-${COLLECTION}-$(date +%Y%m%d-%H%M%S)"
SCRIPTS_GCS="${GCS_BUCKET}/scripts"
COLLECTION_GCS="${GCS_BUCKET}/collections/${COLLECTION}"

# Machine type: gpu_1x_h100_nvl = 1x H100 NVL 94GB
MACHINE_TYPE="${TRAIN_MACHINE_TYPE:-gpu_1x_h100_nvl}"
LAMBDA_API="https://cloud.lambdalabs.com/api/v1"

echo "==> Uploading scripts and collection config to GCS..."
gcloud storage cp "$(dirname "$0")/startup-train.sh" "${SCRIPTS_GCS}/startup-train.sh"
gcloud storage cp "$(dirname "$0")/build_dataset.py" "${SCRIPTS_GCS}/build_dataset.py"
gcloud storage cp "${COLLECTION_YAML}" "${COLLECTION_GCS}/collection.yaml"

# Build user_data: installs gcloud, auths with GCS service account, then downloads and runs startup-train.sh
USER_DATA=$(cat <<BOOTSTRAP
#!/usr/bin/env bash
set -euo pipefail
exec > >(tee -a /var/log/kalpa-bootstrap.log) 2>&1
echo "==> Bootstrap started: \$(date -u)"

# Install gcloud CLI
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  | tee /etc/apt/sources.list.d/google-cloud-sdk.list
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
apt-get update -qq
apt-get install -y -qq google-cloud-cli

# Authenticate with GCS
echo "${GCP_SA_KEY_B64}" | base64 -d > /tmp/sa-key.json
gcloud auth activate-service-account --key-file=/tmp/sa-key.json --quiet
rm -f /tmp/sa-key.json

# Export job config for startup-train.sh
export COLLECTION="${COLLECTION}"
export GCS_BUCKET="${GCS_BUCKET}"
export HF_TOKEN="${HF_TOKEN:-}"
export SHELBY_NETWORK="${SHELBY_NETWORK:-testnet}"
export SHELBY_WALLET_PRIVKEY="${SHELBY_WALLET_PRIVKEY}"
export SHELBY_WALLET_ADDRESS="${SHELBY_WALLET_ADDRESS}"
export LAMBDA_API_KEY="${LAMBDA_API_KEY}"
export LAMBDA_INSTANCE_NAME="${INSTANCE_NAME}"

# Download and run the training script
gcloud storage cp "${SCRIPTS_GCS}/startup-train.sh" /tmp/startup-train.sh
chmod +x /tmp/startup-train.sh
exec /tmp/startup-train.sh
BOOTSTRAP
)

echo "==> Creating training instance: ${INSTANCE_NAME}"
echo "    Machine: ${MACHINE_TYPE} | Region: ${LAMBDA_REGION}"

LAUNCH_PAYLOAD=$(python3 -c "
import json, sys
user_data = sys.stdin.read()
print(json.dumps({
    'region_name': '${LAMBDA_REGION}',
    'instance_type_name': '${MACHINE_TYPE}',
    'ssh_key_names': ['${LAMBDA_SSH_KEY_NAME}'],
    'name': '${INSTANCE_NAME}',
    'user_data': user_data
}))
" <<< "${USER_DATA}")

LAUNCH_RESPONSE=$(curl -sf -X POST "${LAMBDA_API}/instance-operations/launch" \
  -H "Authorization: Bearer ${LAMBDA_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "${LAUNCH_PAYLOAD}")

INSTANCE_ID=$(echo "${LAUNCH_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['instance_ids'][0])")

echo "==> Instance ID: ${INSTANCE_ID}"
echo "    Training is running autonomously. Instance will self-terminate when complete."
echo ""

# Poll until instance terminates (self-deleted by startup-train.sh via Lambda API)
echo "==> Waiting for training to complete (polling every 60s)..."
while true; do
  HTTP_CODE=$(curl -s -o /tmp/lambda-instance.json -w "%{http_code}" \
    "${LAMBDA_API}/instances/${INSTANCE_ID}" \
    -H "Authorization: Bearer ${LAMBDA_API_KEY}")

  if [[ "${HTTP_CODE}" == "404" ]]; then
    echo "==> Instance gone — training complete."
    break
  fi

  STATUS=$(python3 -c "import json; print(json.load(open('/tmp/lambda-instance.json'))['data']['status'])" 2>/dev/null || echo "unknown")

  if [[ "${STATUS}" == "terminated" ]]; then
    echo "==> Instance terminated — training complete."
    break
  fi

  echo "    Status: ${STATUS} — waiting..."
  sleep 60
done

# Pull updated collection.yaml back (startup-train.sh writes Shelby asset IDs)
echo "==> Pulling updated collection.yaml from GCS..."
gcloud storage cp "${COLLECTION_GCS}/collection.yaml" "${COLLECTION_YAML}"

echo ""
echo "==> Training pipeline complete."
echo "    LoRA artifacts written to: ${COLLECTION_GCS}/"
echo "    collection.yaml updated with Shelby asset IDs."
