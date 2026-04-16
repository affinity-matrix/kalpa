#!/usr/bin/env bash
# Polls RunPod for H100 NVL availability and launches training when capacity opens.
#
# Usage: ./scripts/watch-and-train-runpod.sh --collection oregon-coast [--interval 120]
# Runs in the foreground — leave it in a terminal tab or run with nohup.

set -euo pipefail

if [[ -f "$(dirname "$0")/../.env" ]]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi

: "${RUNPOD_API_KEY:?RUNPOD_API_KEY is required}"

COLLECTION=""
INTERVAL=30
GPU_TYPE_ID="${TRAIN_GPU_TYPE:-NVIDIA H100 NVL}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --collection) COLLECTION="$2"; shift 2 ;;
    --interval)   INTERVAL="$2";   shift 2 ;;
    --gpu)        GPU_TYPE_ID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "${COLLECTION}" ]]; then
  echo "Usage: $0 --collection <name> [--interval <seconds>] [--gpu <type-id>]"
  exit 1
fi

SCRIPT_DIR="$(dirname "$0")"

echo "==> Watching for '${GPU_TYPE_ID}' on RunPod"
echo "    Collection: ${COLLECTION}"
echo "    Polling every ${INTERVAL}s — Ctrl+C to stop"
echo ""

while true; do
  AVAILABLE=$(curl -s -X POST "https://api.runpod.io/graphql?api_key=${RUNPOD_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"query\": \"{ gpuTypes { id lowestPrice(input: {gpuCount: 1}) { minimumBidPrice uninterruptablePrice } } }\"}" | \
    python3 -c "
import sys, json
types = (json.load(sys.stdin).get('data') or {}).get('gpuTypes', [])
match = next((t for t in types if t.get('id') == '${GPU_TYPE_ID}'), None)
if match:
    price = (match.get('lowestPrice') or {})
    on_demand = price.get('uninterruptablePrice')
    print('yes' if on_demand is not None else 'no')
else:
    print('no')
" 2>/dev/null || echo "error")

  TIMESTAMP=$(date '+%H:%M:%S')

  if [[ "${AVAILABLE}" == "yes" ]]; then
    echo "[${TIMESTAMP}] Capacity available! Launching training..."
    osascript -e 'display notification "Launching training now" with title "Kalpa: RunPod capacity found"' 2>/dev/null || true
    say "RunPod capacity found, launching training" 2>/dev/null || true

    LAUNCH_EXIT=0
    "${SCRIPT_DIR}/train-runpod.sh" --collection "${COLLECTION}" || LAUNCH_EXIT=$?
    if [[ ${LAUNCH_EXIT} -eq 0 ]]; then
      COLL_YAML="$(dirname "$0")/../collections/${COLLECTION}/collection.yaml"
      LORA_GCS=$(COLL_YAML="${COLL_YAML}" python3 -c "
import yaml, os
try:
    c = yaml.safe_load(open(os.environ['COLL_YAML']))
    print((c.get('artifacts') or {}).get('lora_gcs', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

      if [[ -n "${LORA_GCS}" ]]; then
        NOTIFY_TITLE="Kalpa: Training complete"
        NOTIFY_MSG="LoRA for ${COLLECTION} is ready in GCS."
        SAY_MSG="Hey, the instance has stopped. Training for ${COLLECTION} completed successfully. LoRA weights are ready."
      else
        NOTIFY_TITLE="Kalpa: Training stopped"
        NOTIFY_MSG="Training stopped — check GCS logs."
        SAY_MSG="Hey, the instance has stopped. Training for ${COLLECTION} stopped but no artifacts were found. Check the GCS logs."
      fi
      osascript -e "display notification \"${NOTIFY_MSG}\" with title \"${NOTIFY_TITLE}\"" 2>/dev/null || true
      say "${SAY_MSG}" 2>/dev/null || true
      echo "==> ${SAY_MSG}"
      exit 0
    elif [[ ${LAUNCH_EXIT} -eq 2 ]]; then
      echo "[${TIMESTAMP}] Supply constraint — capacity grabbed before launch. Resuming watch in ${INTERVAL}s..."
      sleep "${INTERVAL}"
      continue
    else
      SAY_MSG="Hey, the instance has stopped. Training for ${COLLECTION} failed with an error. Check the GCS logs for details."
      osascript -e "display notification \"Training failed — check GCS logs.\" with title \"Kalpa: Training stopped\"" 2>/dev/null || true
      say "${SAY_MSG}" 2>/dev/null || true
      echo "==> Training script failed (exit ${LAUNCH_EXIT}). Exiting watcher."
      exit ${LAUNCH_EXIT}
    fi
  elif [[ "${AVAILABLE}" == "error" ]]; then
    echo "[${TIMESTAMP}] API error — retrying..."
  else
    echo "[${TIMESTAMP}] No capacity for '${GPU_TYPE_ID}' — retrying in ${INTERVAL}s"
  fi

  sleep "${INTERVAL}"
done
