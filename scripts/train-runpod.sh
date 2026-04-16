#!/usr/bin/env bash
# Spins up an H100 training pod on RunPod, waits for completion, then tears it down.
# The pod runs startup-train.sh autonomously and self-terminates.
#
# Usage: ./scripts/train-runpod.sh --collection oregon-coast
# Requires: RUNPOD_API_KEY, GCS_BUCKET, GCP_SA_KEY_B64,
#           SHELBY_WALLET_PRIVKEY, SHELBY_WALLET_ADDRESS set in env or .env
#
# Pre-requisite: add your SSH public key in RunPod console → Settings → SSH Keys
#
# To find available GPU type IDs:
#   curl -sf "https://api.runpod.io/graphql?api_key=<key>" \
#     -H "Content-Type: application/json" \
#     -d '{"query":"{ gpuTypes { id displayName } }"}' | python3 -m json.tool

set -euo pipefail

if [[ -f "$(dirname "$0")/../.env" ]]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi

: "${RUNPOD_API_KEY:?RUNPOD_API_KEY is required}"
: "${GCS_BUCKET:?GCS_BUCKET is required}"
: "${GCP_SA_KEY_B64:?GCP_SA_KEY_B64 is required}"
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

POD_NAME="kalpa-train-${COLLECTION}-$(date +%Y%m%d-%H%M%S)"
SCRIPTS_GCS="${GCS_BUCKET}/scripts"
COLLECTION_GCS="${GCS_BUCKET}/collections/${COLLECTION}"
GPU_TYPE_ID="${TRAIN_GPU_TYPE:-NVIDIA H100 NVL}"
SSH_KEY="${RUNPOD_SSH_KEY:-${HOME}/.ssh/id_ed25519}"
RUNPOD_API="https://api.runpod.io/graphql"

# Build GraphQL mutation — Python handles all escaping
MUTATION=$(python3 -c "
import json

env_vars = [
    {'key': 'COLLECTION',             'value': '${COLLECTION}'},
    {'key': 'GCS_BUCKET',             'value': '${GCS_BUCKET}'},
    {'key': 'HF_TOKEN',               'value': '${HF_TOKEN:-}'},
    {'key': 'SHELBY_NETWORK',         'value': '${SHELBY_NETWORK:-testnet}'},
    {'key': 'SHELBY_WALLET_PRIVKEY',  'value': '${SHELBY_WALLET_PRIVKEY}'},
    {'key': 'SHELBY_WALLET_ADDRESS',  'value': '${SHELBY_WALLET_ADDRESS}'},
    {'key': 'RUNPOD_API_KEY',         'value': '${RUNPOD_API_KEY}'},
    {'key': 'GCP_SA_KEY_B64',         'value': '${GCP_SA_KEY_B64}'},
    {'key': 'WANDB_API_KEY',          'value': '${WANDB_API_KEY:-}'},
]
env_gql = '[' + ', '.join(
    '{key: ' + json.dumps(e['key']) + ', value: ' + json.dumps(e['value']) + '}'
    for e in env_vars
) + ']'

mutation = '''mutation {
  podFindAndDeployOnDemand(input: {
    cloudType: SECURE
    gpuCount: 1
    containerDiskInGb: 200
    minVcpuCount: 8
    minMemoryInGb: 48
    gpuTypeId: ''' + json.dumps('${GPU_TYPE_ID}') + '''
    name: ''' + json.dumps('${POD_NAME}') + '''
    imageName: \"runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04\"
    startSsh: true
    startJupyter: false
    ports: \"22/tcp\"
    env: ''' + env_gql + '''
  }) {
    id
  }
}'''

print(json.dumps({'query': mutation}))
")

echo "==> Creating training pod: ${POD_NAME}"
echo "    GPU: ${GPU_TYPE_ID}"

RESPONSE=$(curl -s -X POST "${RUNPOD_API}?api_key=${RUNPOD_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "${MUTATION}" || true)

POD_ID=$(echo "${RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'errors' in data:
    errors = data['errors']
    if any((e.get('extensions') or {}).get('code') == 'SUPPLY_CONSTRAINT' for e in errors):
        print('GraphQL error: ' + str(errors), file=sys.stderr)
        sys.exit(2)
    raise SystemExit('GraphQL error: ' + str(errors))
print(data['data']['podFindAndDeployOnDemand']['id'])
") || {
  rc=$?
  if [[ $rc -eq 2 ]]; then
    echo "ERROR: No instances available (SUPPLY_CONSTRAINT) — capacity was grabbed." >&2
    exit 2
  fi
  exit $rc
}

echo "==> Pod ID: ${POD_ID}"

# Upload scripts now — pod takes several minutes to boot, plenty of time
echo "==> Uploading scripts and collection config to GCS..."
gcloud storage cp "$(dirname "$0")/startup-train.sh" "${SCRIPTS_GCS}/startup-train.sh"
gcloud storage cp "$(dirname "$0")/build_dataset.py" "${SCRIPTS_GCS}/build_dataset.py"
gcloud storage cp "${COLLECTION_YAML}" "${COLLECTION_GCS}/collection.yaml"

echo "==> Waiting for pod to be running and SSH to be ready..."

POD_IP=""
SSH_PORT="22"
for i in $(seq 1 60); do
  sleep 10
  STATUS_RESPONSE=$(curl -s -X POST "${RUNPOD_API}?api_key=${RUNPOD_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"query\": \"{ pod(input: {podId: \\\"${POD_ID}\\\"}) { desiredStatus runtime { ports { ip isIpPublic privatePort publicPort type } } } }\"}" \
    2>/dev/null || echo "{}")

  STATUS=$(echo "${STATUS_RESPONSE}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print((d.get('data') or {}).get('pod', {}).get('desiredStatus', 'unknown'))
" 2>/dev/null || echo "unknown")

  read POD_IP SSH_PORT < <(echo "${STATUS_RESPONSE}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ports = ((d.get('data') or {}).get('pod', {}).get('runtime') or {}).get('ports', []) or []
ssh = next((p for p in ports if p.get('privatePort') == 22), None)
if ssh:
    print(ssh.get('ip',''), ssh.get('publicPort', 22))
else:
    print('', 22)
" 2>/dev/null || echo " 22")

  echo "    [${i}/60] Status: ${STATUS} | IP: ${POD_IP:-pending} | Port: ${SSH_PORT}"

  if [[ "${STATUS}" == "RUNNING" && -n "${POD_IP}" ]]; then
    if ssh -q -p "${SSH_PORT}" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes \
        -i "${SSH_KEY}" "root@${POD_IP}" "echo ok" 2>/dev/null; then
      echo "==> SSH ready."
      break
    fi
  fi
done

if [[ -z "${POD_IP}" ]]; then
  echo "ERROR: Pod never became reachable. Check RunPod console."
  exit 1
fi

# Bootstrap: install gcloud, auth with GCS, kick off startup-train.sh in background
echo "==> Bootstrapping pod and launching training..."
ssh -q -p "${SSH_PORT}" -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${POD_IP}" bash <<REMOTE
set -euo pipefail

# Install gcloud
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  | tee /etc/apt/sources.list.d/google-cloud-sdk.list
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
apt-get update -qq && apt-get install -y -qq google-cloud-cli

# Authenticate with GCS
echo "${GCP_SA_KEY_B64}" | base64 -d > /tmp/sa-key.json
gcloud auth activate-service-account --key-file=/tmp/sa-key.json --quiet
rm -f /tmp/sa-key.json

# Download and launch startup-train.sh in background
gcloud storage cp "${SCRIPTS_GCS}/startup-train.sh" /tmp/startup-train.sh
chmod +x /tmp/startup-train.sh

# Export job config — SSH sessions don't inherit Docker env vars
export COLLECTION="${COLLECTION}"
export GCS_BUCKET="${GCS_BUCKET}"
export HF_TOKEN="${HF_TOKEN:-}"
export SHELBY_NETWORK="${SHELBY_NETWORK:-testnet}"
export SHELBY_WALLET_PRIVKEY="${SHELBY_WALLET_PRIVKEY}"
export SHELBY_WALLET_ADDRESS="${SHELBY_WALLET_ADDRESS}"
export RUNPOD_API_KEY="${RUNPOD_API_KEY}"
export RUNPOD_POD_ID="${POD_ID}"
export WANDB_API_KEY="${WANDB_API_KEY:-}"

nohup /tmp/startup-train.sh > /var/log/kalpa-train.log 2>&1 &
disown \$!
echo "==> Training started (PID \$!)."
REMOTE

echo ""
echo "==> Training running on ${POD_IP}."
echo "    Tail logs: ssh -p ${SSH_PORT} -i ${SSH_KEY} root@${POD_IP} 'tail -f /var/log/kalpa-train.log'"
echo ""

# Poll until pod terminates
echo "==> Waiting for training to complete (polling every 30s)..."
TERMINATION_ALERTED=false
while true; do
  STATUS_RESPONSE=$(curl -sf -X POST "${RUNPOD_API}?api_key=${RUNPOD_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"query\": \"{ pod(input: {podId: \\\"${POD_ID}\\\"}) { desiredStatus } }\"}" \
    2>/dev/null || echo "{}")

  STATUS=$(echo "${STATUS_RESPONSE}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
pod = (d.get('data') or {}).get('pod')
print(pod['desiredStatus'] if pod else 'GONE')
" 2>/dev/null || echo "GONE")

  if [[ "${STATUS}" == "GONE" || "${STATUS}" == "EXITED" || "${STATUS}" == "TERMINATED" ]]; then
    echo "==> Pod gone — training complete."
    break
  fi

  # Watch for the pending-termination sentinel — fire a local alert once
  if [[ "${TERMINATION_ALERTED}" == "false" ]]; then
    if gcloud storage ls "${GCS_BUCKET}/signals/${COLLECTION}-pending-termination.txt" > /dev/null 2>&1; then
      TERMINATION_ALERTED=true
      CANCEL_CMD="gcloud storage cp /dev/null ${GCS_BUCKET}/signals/${COLLECTION}-cancel-termination.txt"
      osascript -e "display notification \"Pipeline done. Instance deletes in ~10 min. To cancel: ${CANCEL_CMD}\" with title \"Kalpa: Verify & cancel?\"" 2>/dev/null || true
      say "Hey, the ${COLLECTION} training pipeline has completed. Verify the artifacts look correct. The instance will self-terminate in about 10 minutes. To cancel termination, run: ${CANCEL_CMD}" 2>/dev/null || true
      echo "==> ALERT: Pipeline complete — instance terminating in ~10 min."
      echo "    To cancel: ${CANCEL_CMD}"
    fi
  fi

  echo "    Status: ${STATUS} — waiting..."
  sleep 30
done

echo "==> Pulling updated collection.yaml from GCS..."
gcloud storage cp "${COLLECTION_GCS}/collection.yaml" "${COLLECTION_YAML}"

# Check the exit code sentinel written by startup-train.sh
REMOTE_EXIT=$(gcloud storage cat "${GCS_BUCKET}/logs/${COLLECTION}-train-exit-code.txt" 2>/dev/null \
  | tr -d '[:space:]' || echo "")

if [[ "${REMOTE_EXIT}" == "0" ]]; then
  : # success
elif [[ -n "${REMOTE_EXIT}" ]]; then
  echo ""
  echo "ERROR: Training failed (exit code: ${REMOTE_EXIT})."
  echo "       Logs: ${GCS_BUCKET}/logs/"
  exit 1
else
  echo "WARNING: No exit code sentinel found — could not confirm success. Check GCS logs."
fi

echo ""
echo "==> Training pipeline complete."
echo "    LoRA artifacts written to: ${COLLECTION_GCS}/"
echo "    collection.yaml updated with Shelby asset IDs."
