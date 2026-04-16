#!/usr/bin/env bash
# Runs on the Lambda Labs inference instance at boot via user_data.
# Downloads models + LoRA from GCS, installs dependencies, starts FastAPI server.
#
# DO NOT run this manually — it is invoked by the start-inference.sh bootstrap.

set -euo pipefail

LOG_FILE="/var/log/kalpa-infer.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "======================================"
echo " Kalpa Inference Server Startup"
echo " Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "======================================"

# --- Read job config from environment (set by start-inference.sh bootstrap via user_data) ---
: "${COLLECTION:?COLLECTION env var is required}"
: "${GCS_BUCKET:?GCS_BUCKET env var is required}"
: "${INFERENCE_API_KEY:?INFERENCE_API_KEY env var is required}"
: "${SHELBY_WALLET_PRIVKEY:?SHELBY_WALLET_PRIVKEY env var is required}"
: "${SHELBY_WALLET_ADDRESS:?SHELBY_WALLET_ADDRESS env var is required}"
: "${SHELBY_NETWORK:=testnet}"

export COLLECTION GCS_BUCKET INFERENCE_API_KEY
export SHELBY_NETWORK SHELBY_WALLET_PRIVKEY SHELBY_WALLET_ADDRESS
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

echo "==> Collection: ${COLLECTION}"

WORK_DIR="/opt/kalpa"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# --- Set up Application Default Credentials for Python GCS SDK ---
# gcloud auth activate-service-account only covers the gcloud CLI, not the Python SDK.
echo "${GCP_SA_KEY_B64}" | base64 -d > "${WORK_DIR}/sa-key.json"
export GOOGLE_APPLICATION_CREDENTIALS="${WORK_DIR}/sa-key.json"

# --- Install system dependencies ---
echo "==> Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq ffmpeg git curl

# Install uv
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="${HOME}/.local/bin:${PATH}"

# Install Node.js + Shelby CLI
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y -qq nodejs
npm install -g @shelby-protocol/cli

# --- Configure Shelby CLI ---
echo "==> Configuring Shelby CLI (network: ${SHELBY_NETWORK})..."
mkdir -p "${HOME}/.shelby"
cat > "${HOME}/.shelby/config.yaml" <<EOF
contexts:
  testnet:
    aptos_network:
      name: testnet
      fullnode: https://api.testnet.aptoslabs.com/v1
      indexer: https://api.testnet.aptoslabs.com/v1/graphql
      pepper: https://api.testnet.aptoslabs.com/keyless/pepper/v0
      prover: https://api.testnet.aptoslabs.com/keyless/prover/v0
    shelby_network:
      rpc_endpoint: https://api.testnet.shelby.xyz/shelby
  shelbynet:
    aptos_network:
      name: shelbynet
      fullnode: https://api.shelbynet.shelby.xyz/v1
      faucet: https://faucet.shelbynet.shelby.xyz
      indexer: https://api.shelbynet.shelby.xyz/v1/graphql
      pepper: https://api.shelbynet.aptoslabs.com/keyless/pepper/v0
      prover: https://api.shelbynet.aptoslabs.com/keyless/prover/v0
    shelby_network:
      rpc_endpoint: https://api.shelbynet.shelby.xyz/shelby

accounts:
  kalpa:
    private_key: ${SHELBY_WALLET_PRIVKEY}
    address: "${SHELBY_WALLET_ADDRESS}"

default_context: ${SHELBY_NETWORK}
default_account: kalpa
EOF
chmod 600 "${HOME}/.shelby/config.yaml"
shelby account list  # sanity check — will fail fast if config is malformed

# --- Download model weights from GCS ---
echo "==> Downloading model weights from GCS (~47 GB)..."
mkdir -p models
gcloud storage rsync -r "${GCS_BUCKET}/models/ltx-2.3-22b-dev/" models/ltx-2.3-22b-dev/
gcloud storage rsync -r "${GCS_BUCKET}/models/ltx-2.3-spatial-upscaler-x2/" models/ltx-2.3-spatial-upscaler-x2/
gcloud storage rsync -r "${GCS_BUCKET}/models/gemma-encoder/" models/gemma-encoder/
# Temporal upscaler omitted: operates on latents with no public ltx_pipelines API.
# Generating at native 24fps instead.

# --- Download LoRA from GCS ---
echo "==> Downloading LoRA for collection: ${COLLECTION}..."
mkdir -p "models/loras/${COLLECTION}"
gcloud storage cp "${GCS_BUCKET}/loras/${COLLECTION}/lora.safetensors" \
  "models/loras/${COLLECTION}/lora.safetensors"

# --- Clone and install LTX-2 ---
echo "==> Cloning LTX-2 repository..."
git clone https://github.com/Lightricks/LTX-2.git ltx2
cd ltx2
uv sync
cd "${WORK_DIR}"

# --- Copy inference server code ---
echo "==> Downloading inference server code from GCS..."
gcloud storage cp "${GCS_BUCKET}/scripts/server.py" ./server.py
gcloud storage cp "${GCS_BUCKET}/scripts/pipeline.py" ./pipeline.py

# Install server dependencies into the ltx2 virtualenv
cd "${WORK_DIR}/ltx2" && uv pip install fastapi uvicorn google-cloud-storage pydantic
cd "${WORK_DIR}"

echo "==> Starting inference server on :8080..."
echo "==> Model will load into GPU memory — /health will return 'loading' until complete."

export MODEL_DIR="${WORK_DIR}/models"
export LTX2_DIR="${WORK_DIR}/ltx2"
export JOBS_TMP_DIR="/tmp/kalpa-jobs"

# Run server using the ltx2 venv (which has ltx_pipelines installed)
"${WORK_DIR}/ltx2/.venv/bin/python" server.py &
SERVER_PID=$!

echo "==> Server PID: ${SERVER_PID}"
echo "${SERVER_PID}" > /var/run/kalpa-server.pid

# Wait for server to be healthy (polls /health until 'online')
echo "==> Waiting for model to load..."
for i in $(seq 1 60); do
  sleep 30
  STATUS=$(curl -sf http://localhost:8080/health | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "unreachable")
  echo "  [${i}/60] Health: ${STATUS}"
  if [[ "${STATUS}" == "online" ]]; then
    echo "==> Server is online and ready."
    break
  fi
done

echo "======================================"
echo " Inference server startup complete"
echo " $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "======================================"
