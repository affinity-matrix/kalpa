#!/usr/bin/env bash
# Spins up an inference pod on RunPod, bootstraps the model server, and returns.
# The pod keeps running until stop-inference-runpod.sh terminates it.
#
# Usage: ./scripts/start-inference-runpod.sh --collection oregon-coast
# Requires: RUNPOD_API_KEY, GCS_BUCKET, GCP_SA_KEY_B64,
#           INFERENCE_API_KEY, SHELBY_WALLET_PRIVKEY, SHELBY_WALLET_ADDRESS set in env or .env

set -euo pipefail

if [[ -f "$(dirname "$0")/../.env" ]]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi

: "${RUNPOD_API_KEY:?RUNPOD_API_KEY is required}"
: "${GCS_BUCKET:?GCS_BUCKET is required}"
: "${GCP_SA_KEY_B64:?GCP_SA_KEY_B64 is required}"
: "${INFERENCE_API_KEY:?INFERENCE_API_KEY is required}"
: "${SHELBY_WALLET_PRIVKEY:?SHELBY_WALLET_PRIVKEY is required}"
: "${SHELBY_WALLET_ADDRESS:?SHELBY_WALLET_ADDRESS is required}"

COLLECTION=""
GPU_TYPE_ID="${INFER_GPU_TYPE:-NVIDIA A100-SXM4-80GB}"
while [[ $# -gt 0 ]]; do
  case $1 in
    --collection) COLLECTION="$2"; shift 2 ;;
    --gpu)        GPU_TYPE_ID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "${COLLECTION}" ]]; then
  echo "Usage: $0 --collection <name> [--gpu <type-id>]"
  exit 1
fi

POD_NAME="kalpa-infer-${COLLECTION}"
SCRIPTS_GCS="${GCS_BUCKET}/scripts"
SSH_KEY="${RUNPOD_SSH_KEY:-${HOME}/.ssh/id_ed25519}"
RUNPOD_API="https://api.runpod.io/graphql"

# Check if an inference pod for this collection is already running
EXISTING=$(curl -s -X POST "${RUNPOD_API}?api_key=${RUNPOD_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ myself { pods { id name desiredStatus } } }"}' | \
  python3 -c "
import sys, json
pods = (json.load(sys.stdin).get('data') or {}).get('myself', {}).get('pods', [])
match = next((p for p in pods if p.get('name') == '${POD_NAME}' and p.get('desiredStatus') not in ('EXITED', 'TERMINATED')), None)
print(match['id'] if match else '')
" 2>/dev/null || echo "")

if [[ -n "${EXISTING}" ]]; then
  echo "==> Pod '${POD_NAME}' already running (ID: ${EXISTING})."
  echo "    Use ./scripts/stop-inference-runpod.sh to tear it down first."
  exit 1
fi

# Build GraphQL mutation — Python handles all escaping
MUTATION=$(python3 -c "
import json

env_vars = [
    {'key': 'COLLECTION',             'value': '${COLLECTION}'},
    {'key': 'GCS_BUCKET',             'value': '${GCS_BUCKET}'},
    {'key': 'INFERENCE_API_KEY',      'value': '${INFERENCE_API_KEY}'},
    {'key': 'SHELBY_NETWORK',         'value': '${SHELBY_NETWORK:-testnet}'},
    {'key': 'SHELBY_WALLET_PRIVKEY',  'value': '${SHELBY_WALLET_PRIVKEY}'},
    {'key': 'SHELBY_WALLET_ADDRESS',  'value': '${SHELBY_WALLET_ADDRESS}'},
    {'key': 'GCP_SA_KEY_B64',         'value': '${GCP_SA_KEY_B64}'},
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
    ports: \"8080/tcp,22/tcp\"
    env: ''' + env_gql + '''
  }) {
    id
  }
}'''

print(json.dumps({'query': mutation}))
")

echo "==> Creating inference pod: ${POD_NAME}"
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
echo "==> Uploading inference server code to GCS..."
gcloud storage cp "$(dirname "$0")/../inference/server.py" "${SCRIPTS_GCS}/server.py"
gcloud storage cp "$(dirname "$0")/../inference/pipeline.py" "${SCRIPTS_GCS}/pipeline.py"
gcloud storage cp "$(dirname "$0")/startup-infer.sh" "${SCRIPTS_GCS}/startup-infer.sh"

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

  read POD_IP SSH_PORT INFER_PORT < <(echo "${STATUS_RESPONSE}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ports = ((d.get('data') or {}).get('pod', {}).get('runtime') or {}).get('ports', []) or []
ssh = next((p for p in ports if p.get('privatePort') == 22), None)
infer = next((p for p in ports if p.get('privatePort') == 8080), None)
ip = ssh.get('ip','') if ssh else ''
print(ip, ssh.get('publicPort', 22) if ssh else 22, infer.get('publicPort', 8080) if infer else '')
" 2>/dev/null || echo " 22 ")

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

echo "==> Bootstrapping pod and launching inference server..."
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

# Download and launch startup-infer.sh in background
gcloud storage cp "${SCRIPTS_GCS}/startup-infer.sh" /tmp/startup-infer.sh
chmod +x /tmp/startup-infer.sh

export COLLECTION="${COLLECTION}"
export GCS_BUCKET="${GCS_BUCKET}"
export INFERENCE_API_KEY="${INFERENCE_API_KEY}"
export SHELBY_NETWORK="${SHELBY_NETWORK:-testnet}"
export SHELBY_WALLET_PRIVKEY="${SHELBY_WALLET_PRIVKEY}"
export SHELBY_WALLET_ADDRESS="${SHELBY_WALLET_ADDRESS}"
export GCP_SA_KEY_B64="${GCP_SA_KEY_B64}"

nohup /tmp/startup-infer.sh > /var/log/kalpa-infer.log 2>&1 &
disown \$!
echo "==> Inference server starting (PID \$!)."
REMOTE

echo ""
echo "==> Pod is up. Model loading into GPU memory (~15-20 min)..."
echo "    Pod ID:  ${POD_ID}"
echo "    SSH:     ssh -p ${SSH_PORT} -i ${SSH_KEY} root@${POD_IP}"
echo "    Logs:    ssh -p ${SSH_PORT} -i ${SSH_KEY} root@${POD_IP} 'tail -f /var/log/kalpa-infer.log'"
echo "    Health:  http://${POD_IP}:${INFER_PORT}/health  (returns 'loading' until ready)"
echo ""
echo "    Update INFERENCE_SERVER_URL in .env:"
echo "    INFERENCE_SERVER_URL=http://${POD_IP}:${INFER_PORT}"
echo ""
echo "    Stop with: ./scripts/stop-inference-runpod.sh --collection ${COLLECTION}"
