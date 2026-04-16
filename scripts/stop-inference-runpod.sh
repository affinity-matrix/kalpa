#!/usr/bin/env bash
# Terminates the RunPod inference pod for a collection.
#
# Usage: ./scripts/stop-inference-runpod.sh --collection oregon-coast

set -euo pipefail

if [[ -f "$(dirname "$0")/../.env" ]]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi

: "${RUNPOD_API_KEY:?RUNPOD_API_KEY is required}"

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

POD_NAME="kalpa-infer-${COLLECTION}"
RUNPOD_API="https://api.runpod.io/graphql"

# Look up pod by name
PODS_RESPONSE=$(curl -s -X POST "${RUNPOD_API}?api_key=${RUNPOD_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ myself { pods { id name desiredStatus runtime { ports { ip isIpPublic privatePort } } } } }"}')

read POD_ID POD_IP < <(echo "${PODS_RESPONSE}" | python3 -c "
import sys, json
pods = (json.load(sys.stdin).get('data') or {}).get('myself', {}).get('pods', [])
match = next((p for p in pods if p.get('name') == '${POD_NAME}'), None)
if not match:
    print('', '')
else:
    ports = (match.get('runtime') or {}).get('ports', []) or []
    pub = next((p for p in ports if p.get('privatePort') == 8080), None)
    ip = pub.get('ip', '') if pub else ''
    print(match['id'], ip)
" 2>/dev/null || echo " ")

if [[ -z "${POD_ID}" ]]; then
  echo "Pod '${POD_NAME}' not found — nothing to stop."
  exit 0
fi

echo "==> Found pod '${POD_NAME}' (ID: ${POD_ID})"

# Check queue depth before terminating
if [[ -n "${POD_IP}" ]]; then
  QUEUE=$(curl -sf --max-time 5 "http://${POD_IP}:8080/health" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('queue_depth', 0))" \
    2>/dev/null || echo "unknown")
  if [[ "${QUEUE}" != "0" && "${QUEUE}" != "unknown" ]]; then
    echo "  WARNING: queue_depth=${QUEUE} — there are jobs in progress."
    read -p "  Terminate anyway? [y/N] " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  fi
fi

curl -s -X POST "${RUNPOD_API}?api_key=${RUNPOD_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"mutation { podTerminate(input: {podId: \\\"${POD_ID}\\\"}) }\"}" > /dev/null

echo "==> Done. Pod termination requested."
