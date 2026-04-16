#!/usr/bin/env bash
# Tails training or inference logs from a running instance.
# Auto-detects provider and falls back to bootstrap log if training hasn't started yet.
#
# Usage:
#   ./scripts/logs.sh --collection oregon-coast [--type train|infer] [--bootstrap]

set -euo pipefail

if [[ -f "$(dirname "$0")/../.env" ]]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi

COLLECTION=""
TYPE="train"
BOOTSTRAP=false
SSH_KEY="${RUNPOD_SSH_KEY:-${HOME}/.ssh/id_ed25519}"
SSH_PORT="22"

while [[ $# -gt 0 ]]; do
  case $1 in
    --collection) COLLECTION="$2"; shift 2 ;;
    --type)       TYPE="$2";       shift 2 ;;
    --bootstrap)  BOOTSTRAP=true;  shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "${COLLECTION}" ]]; then
  echo "Usage: $0 --collection <name> [--type train|infer] [--bootstrap]"
  exit 1
fi

if [[ "${TYPE}" == "train" ]]; then
  POD_NAME_PREFIX="kalpa-train-${COLLECTION}"
  LOG_FILE="/var/log/kalpa-train.log"
  BOOTSTRAP_LOG="/var/log/kalpa-bootstrap.log"
  SSH_USER_RUNPOD="root"
  SSH_USER_LAMBDA="ubuntu"
else
  POD_NAME_PREFIX="kalpa-infer-${COLLECTION}"
  LOG_FILE="/var/log/kalpa-infer.log"
  BOOTSTRAP_LOG="/var/log/kalpa-bootstrap.log"
  SSH_USER_RUNPOD="root"
  SSH_USER_LAMBDA="ubuntu"
fi

# Resolve IP and provider
INSTANCE_IP=""
SSH_USER=""

# Check RunPod first
if [[ -n "${RUNPOD_API_KEY:-}" ]]; then
  RUNPOD_RESULT=$(curl -s -X POST "https://api.runpod.io/graphql?api_key=${RUNPOD_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"query": "{ myself { pods { name desiredStatus runtime { ports { ip privatePort publicPort } } } } }"}' \
    2>/dev/null || echo "{}")

  read INSTANCE_IP SSH_PORT < <(echo "${RUNPOD_RESULT}" | python3 -c "
import sys, json
pods = (json.load(sys.stdin).get('data') or {}).get('myself', {}).get('pods', [])
match = [p for p in pods if p.get('name','').startswith('${POD_NAME_PREFIX}') and p.get('desiredStatus') == 'RUNNING']
if match:
    ports = (match[0].get('runtime') or {}).get('ports', []) or []
    ssh = next((x for x in ports if x.get('privatePort') == 22), None)
    print(ssh.get('ip','') if ssh else '', ssh.get('publicPort',22) if ssh else 22)
else:
    print('', 22)
" 2>/dev/null || echo " 22")

  if [[ -n "${INSTANCE_IP}" ]]; then
    SSH_USER="${SSH_USER_RUNPOD}"
    echo "==> Found on RunPod: ${INSTANCE_IP}:${SSH_PORT}"
  fi
fi

# Check Lambda if not found on RunPod
if [[ -z "${INSTANCE_IP}" && -n "${LAMBDA_API_KEY:-}" ]]; then
  LAMBDA_RESULT=$(curl -sf "https://cloud.lambdalabs.com/api/v1/instances" \
    -H "Authorization: Bearer ${LAMBDA_API_KEY}" \
    2>/dev/null || echo "{}")

  INSTANCE_IP=$(echo "${LAMBDA_RESULT}" | python3 -c "
import sys, json
instances = (json.load(sys.stdin).get('data') or [])
match = [i for i in instances if i.get('name','').startswith('${POD_NAME_PREFIX}')]
print(match[0].get('ip', '') if match else '')
" 2>/dev/null || echo "")

  if [[ -n "${INSTANCE_IP}" ]]; then
    SSH_USER="${SSH_USER_LAMBDA}"
    echo "==> Found on Lambda Labs: ${INSTANCE_IP}"
  fi
fi

if [[ -z "${INSTANCE_IP}" ]]; then
  echo "ERROR: No running instance found for collection '${COLLECTION}' (type: ${TYPE})."
  echo "       Run ./scripts/status.sh to see what's active."
  exit 1
fi

# Choose which log to tail
if [[ "${BOOTSTRAP}" == "true" ]]; then
  TARGET_LOG="${BOOTSTRAP_LOG}"
  echo "==> Tailing bootstrap log (use without --bootstrap for training log)..."
else
  # Check if the main log exists yet; fall back to bootstrap log if not
  LOG_EXISTS=$(ssh -q -p "${SSH_PORT}" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes \
    -i "${SSH_KEY}" "${SSH_USER}@${INSTANCE_IP}" \
    "test -s '${LOG_FILE}' && echo yes || echo no" 2>/dev/null || echo "no")

  if [[ "${LOG_EXISTS}" == "no" ]]; then
    TARGET_LOG="${BOOTSTRAP_LOG}"
    echo "==> Training log not yet available — showing bootstrap log instead."
    echo "    (Re-run without --bootstrap once training starts)"
  else
    TARGET_LOG="${LOG_FILE}"
  fi
fi

echo "==> ${SSH_USER}@${INSTANCE_IP}:${TARGET_LOG}"
echo "    Ctrl+C to stop tailing."
echo ""

ssh -q -p "${SSH_PORT}" -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${SSH_USER}@${INSTANCE_IP}" \
  "tail -f '${TARGET_LOG}'" \
  | awk 'BEGIN { prev = systime() }
         { now = systime(); delta = now - prev; prev = now
           printf "[%s +%ds] %s\n", strftime("%H:%M:%S"), delta, $0
           fflush() }'
