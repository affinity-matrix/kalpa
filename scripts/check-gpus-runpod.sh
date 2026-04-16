#!/usr/bin/env bash
# Shows availability and on-demand pricing for H100, H200, and A100 variants on RunPod.
#
# Usage: ./scripts/check-gpus-runpod.sh

if [[ -f "$(dirname "$0")/../.env" ]]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi

: "${RUNPOD_API_KEY:?RUNPOD_API_KEY is required}"

RESPONSE=$(curl -sf -X POST "https://api.runpod.io/graphql?api_key=${RUNPOD_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ gpuTypes { id displayName memoryInGb lowestPrice(input: {gpuCount: 1}) { minimumBidPrice uninterruptablePrice } } }"}')

echo "${RESPONSE}" | python3 -c "
import sys, json

data = json.load(sys.stdin)
types = (data.get('data') or {}).get('gpuTypes', [])

targets = [t for t in types if any(x in t.get('id', '') for x in ('H100', 'H200', 'A100'))]
targets.sort(key=lambda t: t.get('id', ''))

if not targets:
    print('No H100/H200/A100 GPU types found.')
    sys.exit(0)

print(f'  {\"GPU\":<36} {\"VRAM\":>6}  {\"ON-DEMAND\":>10}  {\"SPOT\":>8}')
print('  ' + '-' * 66)
for t in targets:
    gpu_id    = t.get('id', '?')
    name      = t.get('displayName', gpu_id)
    vram      = t.get('memoryInGb', '?')
    price     = t.get('lowestPrice') or {}
    on_demand = price.get('uninterruptablePrice')
    spot      = price.get('minimumBidPrice')

    on_demand_str = f'\${on_demand:.2f}/hr' if on_demand is not None else 'unavailable'
    spot_str      = f'\${spot:.2f}/hr'      if spot      is not None else '-'

    print(f'  {gpu_id:<36} {str(vram)+\"GB\":>6}  {on_demand_str:>10}  {spot_str:>8}')
"
