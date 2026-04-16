#!/usr/bin/env bash
# Terminates a Kalpa instance by ID, or all Kalpa instances with -a.
# The script tries both RunPod and Lambda — no need to specify the provider.
#
# Usage:
#   ./scripts/kill.sh <instance-id>      # kill a specific instance
#   ./scripts/kill.sh -a                 # kill ALL running kalpa instances

set -euo pipefail

if [[ -f "$(dirname "$0")/../.env" ]]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <instance-id>"
  echo "       $0 -a"
  exit 1
fi

kill_runpod() {
  local id="$1"
  RESULT=$(curl -sf -X POST "https://api.runpod.io/graphql?api_key=${RUNPOD_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"query\": \"mutation { podTerminate(input: {podId: \\\"${id}\\\"}) }\"}" \
    2>/dev/null || echo "{}")
  if echo "${RESULT}" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'errors' not in d else 1)" 2>/dev/null; then
    echo "  Terminated on RunPod: ${id}"
    return 0
  fi
  return 1
}

kill_lambda() {
  local id="$1"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "https://cloud.lambdalabs.com/api/v1/instance-operations/terminate" \
    -H "Authorization: Bearer ${LAMBDA_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"instance_ids\": [\"${id}\"]}" 2>/dev/null || echo "000")
  if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "  Terminated on Lambda: ${id}"
    return 0
  fi
  return 1
}

kill_instance() {
  local id="$1"
  local killed=false

  if [[ -n "${RUNPOD_API_KEY:-}" ]]; then
    kill_runpod "${id}" && killed=true || true
  fi

  if [[ "${killed}" == "false" && -n "${LAMBDA_API_KEY:-}" ]]; then
    kill_lambda "${id}" && killed=true || true
  fi

  if [[ "${killed}" == "false" ]]; then
    echo "  WARNING: Could not terminate ${id} on any provider (ID not found or API error)."
  fi
}

if [[ "$1" == "-a" ]]; then
  echo "==> Terminating ALL running Kalpa instances..."
  KILLED=0

  # RunPod
  if [[ -n "${RUNPOD_API_KEY:-}" ]]; then
    RESPONSE=$(curl -sf -X POST "https://api.runpod.io/graphql?api_key=${RUNPOD_API_KEY}" \
      -H "Content-Type: application/json" \
      -d '{"query": "{ myself { pods { id name desiredStatus } } }"}' \
      2>/dev/null || echo "{}")

    IDS=$(echo "${RESPONSE}" | python3 -c "
import sys, json
pods = (json.load(sys.stdin).get('data') or {}).get('myself', {}).get('pods', [])
for p in pods:
    if 'kalpa' in p.get('name','').lower() and p.get('desiredStatus') not in ('EXITED','TERMINATED'):
        print(p['id'])
" 2>/dev/null || true)

    for id in ${IDS}; do
      kill_runpod "${id}" && KILLED=$((KILLED + 1)) || true
    done
  fi

  # Lambda
  if [[ -n "${LAMBDA_API_KEY:-}" ]]; then
    RESPONSE=$(curl -sf "https://cloud.lambdalabs.com/api/v1/instances" \
      -H "Authorization: Bearer ${LAMBDA_API_KEY}" \
      2>/dev/null || echo "{}")

    IDS=$(echo "${RESPONSE}" | python3 -c "
import sys, json
instances = (json.load(sys.stdin).get('data') or [])
for i in instances:
    if 'kalpa' in i.get('name','').lower():
        print(i['id'])
" 2>/dev/null || true)

    for id in ${IDS}; do
      kill_lambda "${id}" && KILLED=$((KILLED + 1)) || true
    done
  fi

  if [[ "${KILLED}" -eq 0 ]]; then
    echo "No running Kalpa instances found."
  else
    echo "==> ${KILLED} instance(s) terminated."
  fi

else
  INSTANCE_ID="$1"
  echo "==> Terminating instance: ${INSTANCE_ID}"
  kill_instance "${INSTANCE_ID}"
fi
