#!/usr/bin/env bash
# Shows all running Kalpa instances across RunPod and Lambda Labs.
# Use this to quickly check if anything is running (and costing money).
#
# Usage: ./scripts/status.sh

set -euo pipefail

if [[ -f "$(dirname "$0")/../.env" ]]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi

SSH_KEY="${RUNPOD_SSH_KEY:-${HOME}/.ssh/id_ed25519}"
FOUND=0

# --- RunPod ---
if [[ -n "${RUNPOD_API_KEY:-}" ]]; then
  echo "=== RunPod ==="
  RESPONSE=$(curl -sf -X POST "https://api.runpod.io/graphql?api_key=${RUNPOD_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"query": "{ myself { pods { id name desiredStatus runtime { uptimeInSeconds ports { ip privatePort publicPort } } machine { gpuDisplayName } } } }"}' \
    2>/dev/null || echo "{}")

  PODS=$(echo "${RESPONSE}" | python3 -c "
import sys, json
pods = (json.load(sys.stdin).get('data') or {}).get('myself', {}).get('pods', [])
kalpa = [p for p in pods if 'kalpa' in p.get('name','').lower()]
for p in kalpa:
    uptime = (p.get('runtime') or {}).get('uptimeInSeconds', 0)
    hours = uptime // 3600
    mins = (uptime % 3600) // 60
    ports = (p.get('runtime') or {}).get('ports', []) or []
    ssh = next((x for x in ports if x.get('privatePort') == 22), None)
    ip = ssh.get('ip', 'pending') if ssh else 'pending'
    port = ssh.get('publicPort', 22) if ssh else 22
    gpu = (p.get('machine') or {}).get('gpuDisplayName', '?')
    print(f\"  {p['name']}\")
    print(f\"    ID:      {p['id']}\")
    print(f\"    Status:  {p['desiredStatus']}\")
    print(f\"    GPU:     {gpu}\")
    print(f\"    IP:      {ip}:{port}\")
    print(f\"    Uptime:  {hours}h {mins}m\")
    print(f\"    Logs:    ssh -p {port} -i ${SSH_KEY} root@{ip} 'tail -f /var/log/kalpa-train.log'\")
    print()
if not kalpa:
    print('  (no kalpa pods running)')
" 2>/dev/null || echo "  (error querying RunPod API)")

  echo "${PODS}"
  [[ "${PODS}" != *"no kalpa pods"* && "${PODS}" != *"error"* ]] && FOUND=1
else
  echo "=== RunPod === (RUNPOD_API_KEY not set)"
fi

# --- Lambda Labs ---
if [[ -n "${LAMBDA_API_KEY:-}" ]]; then
  echo "=== Lambda Labs ==="
  RESPONSE=$(curl -sf "https://cloud.lambdalabs.com/api/v1/instances" \
    -H "Authorization: Bearer ${LAMBDA_API_KEY}" \
    2>/dev/null || echo "{}")

  INSTANCES=$(echo "${RESPONSE}" | python3 -c "
import sys, json
instances = (json.load(sys.stdin).get('data') or [])
kalpa = [i for i in instances if 'kalpa' in i.get('name','').lower()]
for i in kalpa:
    ip = i.get('ip', 'no-ip')
    itype = (i.get('instance_type') or {}).get('name', '?')
    print(f\"  {i['name']}\")
    print(f\"    ID:      {i['id']}\")
    print(f\"    Status:  {i['status']}\")
    print(f\"    Type:    {itype}\")
    print(f\"    IP:      {ip}\")
    print(f\"    Logs:    ssh -i ${SSH_KEY} ubuntu@{ip} 'tail -f /var/log/kalpa-train.log'\")
    print()
if not kalpa:
    print('  (no kalpa instances running)')
" 2>/dev/null || echo "  (error querying Lambda API)")

  echo "${INSTANCES}"
  [[ "${INSTANCES}" != *"no kalpa instances"* && "${INSTANCES}" != *"error"* ]] && FOUND=1
else
  echo "=== Lambda Labs === (LAMBDA_API_KEY not set)"
fi

if [[ "${FOUND}" == "0" ]]; then
  echo "No running Kalpa instances found. Nothing is costing money."
fi
