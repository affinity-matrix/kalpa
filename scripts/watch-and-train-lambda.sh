#!/usr/bin/env bash
# Polls Lambda Labs for instance availability and launches training when capacity opens.
#
# Usage: ./scripts/watch-and-train.sh --collection oregon-coast [--interval 120]
# Runs in the foreground — leave it in a terminal tab or run with nohup.

set -euo pipefail

if [[ -f "$(dirname "$0")/../.env" ]]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi

: "${LAMBDA_API_KEY:?LAMBDA_API_KEY is required}"
: "${LAMBDA_REGION:?LAMBDA_REGION is required}"

COLLECTION=""
INTERVAL=120  # seconds between polls
MACHINE_TYPE="${TRAIN_MACHINE_TYPE:-gpu_1x_h100_nvl}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --collection) COLLECTION="$2"; shift 2 ;;
    --interval)   INTERVAL="$2";   shift 2 ;;
    --machine)    MACHINE_TYPE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "${COLLECTION}" ]]; then
  echo "Usage: $0 --collection <name> [--interval <seconds>] [--machine <type>]"
  exit 1
fi

LAMBDA_API="https://cloud.lambdalabs.com/api/v1"
SCRIPT_DIR="$(dirname "$0")"

echo "==> Watching for ${MACHINE_TYPE} in ${LAMBDA_REGION}"
echo "    Collection: ${COLLECTION}"
echo "    Polling every ${INTERVAL}s — Ctrl+C to stop"
echo ""

while true; do
  AVAILABLE=$(curl -sf "${LAMBDA_API}/instance-types" \
    -H "Authorization: Bearer ${LAMBDA_API_KEY}" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', {})
info = data.get('${MACHINE_TYPE}', {})
regions = [r['name'] for r in info.get('regions_with_capacity_available', [])]
print('yes' if '${LAMBDA_REGION}' in regions else 'no')
" 2>/dev/null || echo "error")

  TIMESTAMP=$(date '+%H:%M:%S')

  if [[ "${AVAILABLE}" == "yes" ]]; then
    echo "[${TIMESTAMP}] Capacity available! Launching training..."
    # macOS notification
    osascript -e 'display notification "Launching training now" with title "Kalpa: Lambda capacity found"' 2>/dev/null || true
    say "Lambda capacity found, launching training" 2>/dev/null || true

    TRAIN_EXIT=0
    "${SCRIPT_DIR}/train.sh" --collection "${COLLECTION}" || TRAIN_EXIT=$?

    COLL_YAML="$(dirname "$0")/../collections/${COLLECTION}/collection.yaml"
    LORA_GCS=$(COLL_YAML="${COLL_YAML}" python3 -c "
import yaml, os, sys
try:
    c = yaml.safe_load(open(os.environ['COLL_YAML']))
    print((c.get('artifacts') or {}).get('lora_gcs', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

    if [[ ${TRAIN_EXIT} -eq 0 && -n "${LORA_GCS}" ]]; then
      NOTIFY_TITLE="Kalpa: Training complete"
      NOTIFY_MSG="LoRA for ${COLLECTION} is ready in GCS."
      SAY_MSG="Hey, the instance has stopped. Training for ${COLLECTION} completed successfully. LoRA weights are ready."
    else
      NOTIFY_TITLE="Kalpa: Training stopped"
      NOTIFY_MSG="Training stopped — check GCS logs."
      SAY_MSG="Hey, the instance has stopped. Training for ${COLLECTION} failed with an error. Check the GCS logs for details."
    fi
    osascript -e "display notification \"${NOTIFY_MSG}\" with title \"${NOTIFY_TITLE}\"" 2>/dev/null || true
    say "${SAY_MSG}" 2>/dev/null || true
    echo "==> ${SAY_MSG}"
    exit ${TRAIN_EXIT}
  elif [[ "${AVAILABLE}" == "error" ]]; then
    echo "[${TIMESTAMP}] API error — retrying..."
  else
    echo "[${TIMESTAMP}] No capacity for ${MACHINE_TYPE} in ${LAMBDA_REGION} — retrying in ${INTERVAL}s"
  fi

  sleep "${INTERVAL}"
done
