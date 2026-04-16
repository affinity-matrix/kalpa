#!/usr/bin/env bash
# Gracefully stops the inference server and terminates the Lambda instance.
#
# Usage: ./scripts/stop-inference.sh --collection oregon-coast

set -euo pipefail

if [[ -f "$(dirname "$0")/../.env" ]]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi

: "${LAMBDA_API_KEY:?LAMBDA_API_KEY is required}"

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
LAMBDA_API="https://cloud.lambdalabs.com/api/v1"

# Look up instance by name
INSTANCES_JSON=$(curl -sf "${LAMBDA_API}/instances" \
  -H "Authorization: Bearer ${LAMBDA_API_KEY}")

INSTANCE_ID=$(echo "${INSTANCES_JSON}" | python3 -c "
import sys, json
instances = json.load(sys.stdin)['data']
match = [i for i in instances if i.get('name') == '${INSTANCE_NAME}']
print(match[0]['id'] if match else '')
" 2>/dev/null || echo "")

if [[ -z "${INSTANCE_ID}" ]]; then
  echo "Instance '${INSTANCE_NAME}' not found — nothing to stop."
  exit 0
fi

INSTANCE_IP=$(echo "${INSTANCES_JSON}" | python3 -c "
import sys, json
instances = json.load(sys.stdin)['data']
match = [i for i in instances if i.get('name') == '${INSTANCE_NAME}']
print(match[0].get('ip', '') if match else '')
" 2>/dev/null || echo "")

echo "==> Stopping inference server: ${INSTANCE_NAME} (ID: ${INSTANCE_ID})..."

# Let any in-flight job finish — check queue depth first
if [[ -n "${INSTANCE_IP}" ]]; then
  QUEUE=$(curl -sf --max-time 5 "http://${INSTANCE_IP}:8080/health" \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('queue_depth',0))" \
    2>/dev/null || echo "unknown")
  if [[ "${QUEUE}" != "0" && "${QUEUE}" != "unknown" ]]; then
    echo "  WARNING: queue_depth=${QUEUE} — there are jobs in progress."
    read -p "  Terminate anyway? [y/N] " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  fi
fi

curl -sf -X POST "${LAMBDA_API}/instance-operations/terminate" \
  -H "Authorization: Bearer ${LAMBDA_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"instance_ids\": [\"${INSTANCE_ID}\"]}" > /dev/null

echo "==> Done. Instance termination requested."
