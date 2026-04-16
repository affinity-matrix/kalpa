#!/usr/bin/env bash
# Cancels the pending self-termination for a training instance.
# Run this within the 10-minute window after training completes.
#
# Usage: ./scripts/keep-instance.sh --collection oregon-coast

set -euo pipefail

if [[ -f "$(dirname "$0")/../.env" ]]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi

: "${GCS_BUCKET:?GCS_BUCKET is required}"

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

PENDING_SENTINEL="${GCS_BUCKET}/signals/${COLLECTION}-pending-termination.txt"
CANCEL_SENTINEL="${GCS_BUCKET}/signals/${COLLECTION}-cancel-termination.txt"

# Check that there's actually a pending termination to cancel
if ! gcloud storage ls "${PENDING_SENTINEL}" > /dev/null 2>&1; then
  echo "No pending termination found for '${COLLECTION}'. Nothing to cancel."
  exit 0
fi

echo "==> Writing cancel sentinel for '${COLLECTION}'..."
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | gcloud storage cp - "${CANCEL_SENTINEL}"
echo "==> Done. The instance will stay alive — terminate manually when finished."
