#!/usr/bin/env bash
# Spins up an H100 NVL inference instance on Lambda Labs.
# The instance runs startup-infer.sh, pre-loads the model, and starts FastAPI.
#
# Usage: ./scripts/start-inference.sh --collection oregon-coast
# Requires: LAMBDA_API_KEY, LAMBDA_SSH_KEY_NAME, LAMBDA_REGION, GCS_BUCKET,
#           GCP_SA_KEY_B64, INFERENCE_API_KEY, SHELBY_* in env

set -euo pipefail

if [[ -f "$(dirname "$0")/../.env" ]]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi

: "${LAMBDA_API_KEY:?LAMBDA_API_KEY is required}"
: "${LAMBDA_SSH_KEY_NAME:?LAMBDA_SSH_KEY_NAME is required}"
: "${LAMBDA_REGION:?LAMBDA_REGION is required}"
: "${GCS_BUCKET:?GCS_BUCKET is required}"
: "${GCP_SA_KEY_B64:?GCP_SA_KEY_B64 is required}"
: "${INFERENCE_API_KEY:?INFERENCE_API_KEY is required}"
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

INSTANCE_NAME="kalpa-infer-${COLLECTION}"
SCRIPTS_GCS="${GCS_BUCKET}/scripts"
MACHINE_TYPE="${INFER_MACHINE_TYPE:-gpu_1x_h100_nvl}"
LAMBDA_API="https://cloud.lambdalabs.com/api/v1"

# Check if instance already exists
EXISTING=$(curl -sf "${LAMBDA_API}/instances" \
  -H "Authorization: Bearer ${LAMBDA_API_KEY}" | \
  python3 -c "
import sys, json
instances = json.load(sys.stdin)['data']
match = [i['id'] for i in instances if i.get('name') == '${INSTANCE_NAME}']
print(match[0] if match else '')
" 2>/dev/null || echo "")

if [[ -n "${EXISTING}" ]]; then
  echo "==> Instance '${INSTANCE_NAME}' already exists (ID: ${EXISTING})."
  echo "    Use ./scripts/stop-inference.sh to tear it down first."
  exit 1
fi

echo "==> Uploading inference server code to GCS..."
gcloud storage cp "$(dirname "$0")/../inference/server.py" "${SCRIPTS_GCS}/server.py"
gcloud storage cp "$(dirname "$0")/../inference/pipeline.py" "${SCRIPTS_GCS}/pipeline.py"
gcloud storage cp "$(dirname "$0")/startup-infer.sh" "${SCRIPTS_GCS}/startup-infer.sh"

# Build user_data bootstrap
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

# Export job config for startup-infer.sh
export COLLECTION="${COLLECTION}"
export GCS_BUCKET="${GCS_BUCKET}"
export INFERENCE_API_KEY="${INFERENCE_API_KEY}"
export SHELBY_NETWORK="${SHELBY_NETWORK:-testnet}"
export SHELBY_WALLET_PRIVKEY="${SHELBY_WALLET_PRIVKEY}"
export SHELBY_WALLET_ADDRESS="${SHELBY_WALLET_ADDRESS}"

# Download and run the inference startup script
gcloud storage cp "${SCRIPTS_GCS}/startup-infer.sh" /tmp/startup-infer.sh
chmod +x /tmp/startup-infer.sh
exec /tmp/startup-infer.sh
BOOTSTRAP
)

echo "==> Creating inference instance: ${INSTANCE_NAME}"
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
echo "==> Waiting for instance to be active..."

INSTANCE_IP=""
for i in $(seq 1 30); do
  sleep 10
  INSTANCE_DATA=$(curl -sf "${LAMBDA_API}/instances/${INSTANCE_ID}" \
    -H "Authorization: Bearer ${LAMBDA_API_KEY}" | \
    python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['data']))")
  STATUS=$(echo "${INSTANCE_DATA}" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['status'])")
  if [[ "${STATUS}" == "active" ]]; then
    INSTANCE_IP=$(echo "${INSTANCE_DATA}" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('ip',''))")
    break
  fi
  echo "    [${i}/30] Status: ${STATUS}..."
done

if [[ -z "${INSTANCE_IP}" ]]; then
  echo "WARNING: Could not determine instance IP. Check Lambda console."
fi

echo ""
echo "==> Instance active. Model is loading into GPU memory (~15-20 min)..."
echo "    Public IP: ${INSTANCE_IP}"
echo "    Update INFERENCE_SERVER_URL in .env: http://${INSTANCE_IP}:8080"
echo ""
echo "    Tail startup logs:"
echo "    ssh ubuntu@${INSTANCE_IP} 'sudo tail -f /var/log/kalpa-infer.log'"
