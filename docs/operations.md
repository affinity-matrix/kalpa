# Operations

Day-to-day runbook for Kalpa: spinning up and tearing down training and inference
sessions, monitoring, debugging, and cost management.

---

## Demo Day Checklist

### ~30 minutes before

- [ ] Confirm `INFERENCE_API_KEY` is set in both `.env` and Vercel env vars
- [ ] Confirm `SHELBY_WALLET_PRIVKEY`, `SHELBY_WALLET_ADDRESS`, `SHELBY_NETWORK` are set
- [ ] Confirm the collection's LoRA has been trained (`artifacts.lora_gcs` is not null in collection YAML)
- [ ] Run `./scripts/check-gpus-runpod.sh` to confirm A100 availability

### ~20 minutes before

```bash
./scripts/start-inference-runpod.sh --collection oregon-coast
```

Wait for the script to print the pod's public IP. **Update `INFERENCE_SERVER_URL`** in:
1. Your local `.env`: `INFERENCE_SERVER_URL=http://{pod-ip}:8080`
2. Vercel project environment settings (Settings → Environment Variables)

The script will then poll `/health` every 30s. When it exits, the server is loading.

### When `/health` returns `status: "online"`

The web app automatically detects this and shows the prompt form. You're ready.

If you need to check manually:
```bash
curl http://{pod-ip}:8080/health
```

### After the demo

```bash
./scripts/stop-inference-runpod.sh --collection oregon-coast
```

**Always stop the server.** A100 pods cost ~$3–4/hour on RunPod.

---

## Training a LoRA

### Start training

```bash
# RunPod (primary)
./scripts/train-runpod.sh --collection oregon-coast

# Lambda Labs (secondary)
./scripts/train-lambda.sh --collection oregon-coast
```

The script blocks and polls until the pod self-terminates, then downloads the
updated `collection.yaml`. You can also Ctrl-C out of the script — training
continues on the pod and self-terminates regardless.

### Monitor training

While training is running, tail logs from your Mac:
```bash
./scripts/logs.sh --collection oregon-coast
```

Check if the pod is still running:
```bash
./scripts/status.sh
```

### Cancel a training run

To stop training immediately:
```bash
./scripts/kill.sh --collection oregon-coast
```

To cancel the 10-minute auto-termination window after a failure (to SSH in and debug):
```bash
gsutil cp /dev/null \
  gs://kalpa-assets/oregon-coast-cancel-termination.txt
```

Then manually terminate when done:
```bash
./scripts/kill.sh --collection oregon-coast
```

### Check GPU availability before starting

```bash
./scripts/check-gpus-runpod.sh
```

Prints currently available H100 pods on RunPod community cloud. If none are available,
try again in a few minutes or use Lambda Labs instead.

---

## Inference Server Operations

### Start (RunPod)
```bash
./scripts/start-inference-runpod.sh --collection oregon-coast
```

### Start (Lambda Labs)
```bash
./scripts/start-inference-lambda.sh --collection oregon-coast
```

### Watch startup logs
```bash
./scripts/watch-and-infer-runpod.sh --collection oregon-coast
```

### Stop (RunPod)
```bash
./scripts/stop-inference-runpod.sh --collection oregon-coast
```

### Stop (Lambda Labs)
```bash
./scripts/stop-inference-lambda.sh --collection oregon-coast
```

### Force-terminate
```bash
./scripts/kill.sh --collection oregon-coast
```

### Check server health manually
```bash
curl http://{pod-ip}:8080/health
```

### Check a specific job status
```bash
curl http://{pod-ip}:8080/status/{job_id}
```

---

## Keeping a Pod Alive

Training pods self-terminate after completion. If you need to prevent a pod from
terminating (e.g., to inspect it after a run), use:

```bash
./scripts/keep-instance.sh --collection oregon-coast
```

This periodically pings the pod to prevent inactivity timeouts. Remember to manually
terminate the pod when you're done:

```bash
./scripts/kill.sh --collection oregon-coast
```

---

## Checking Costs

| Resource | Cost | Notes |
|----------|------|-------|
| RunPod H100 80GB | ~$3.49/hr | Training only — self-terminates |
| RunPod A100 80GB | ~$2.99/hr | Inference — stays up until stopped |
| Lambda Labs H100 | varies | Check Lambda dashboard |
| Lambda Labs A100 | varies | Check Lambda dashboard |
| GCS storage | ~$0.02/GB/month | Models (~47 GB) + LoRAs + outputs |
| GCS egress | ~$0.12/GB | For model downloads to pods |
| Vercel | Free tier | Web app |

A typical demo session (20 min model load + 2 hr demo) costs ~$10 in RunPod A100 time.
A training run (~2 hours) costs ~$7 in RunPod H100 time.

---

## Common Issues

### Web app shows "Demo is offline"

The inference server is not running or not reachable.

1. Check if a pod is running: `./scripts/status.sh`
2. If running, verify `INFERENCE_SERVER_URL` in Vercel points to the correct IP
3. If not running, start the server: `./scripts/start-inference-runpod.sh --collection oregon-coast`

### `/health` stays `status: "loading"` for >25 minutes

Model loading normally takes 15–20 min. If it exceeds 25 min:

1. Check startup logs: `./scripts/logs.sh --collection oregon-coast`
2. Look for errors in model download (gsutil errors) or model load (CUDA/memory errors)
3. Common cause: GCS download stalled — tail logs, look for the last downloaded file

### Job stuck in `status: "pending"` for >15 minutes

The background worker may have crashed:

1. Check inference server logs: `./scripts/logs.sh --collection oregon-coast`
2. Look for OOM errors (top 30 allocations are logged on OOM)
3. If OOM: the model is too large for the current GPU — ensure you're on A100 80GB
4. Restart the server: stop, then start again

### Job `status: "failed"` with CUDA OOM

The generation ran out of GPU memory. This should not happen on A100 80GB with the
current configuration, but can occur if:
- Another process is using GPU memory on the pod
- The pod was assigned a degraded GPU

Check the error message in the job status response. If OOM, the server logs a snapshot
of the top 30 live CUDA allocations >= 100 MiB — look for unexpected tenants.

### Shelby upload fails at end of training

The training run succeeded but Shelby upload failed. `collection.yaml` in GCS will
have `artifacts.shelby_lora: null`.

1. Check training logs in GCS: `gsutil cat gs://kalpa-assets/logs/oregon-coast-train-*.log`
2. Common causes: wallet not funded (ShelbyUSD), incorrect env vars
3. Test manually: `shelby upload /tmp/test.txt kalpa-test -e "in 1 hour"`
4. Once fixed, re-run training (weights are cheap to re-generate, ~2 hours)

### Inference server can't find LoRA

Startup log shows "LoRA not found at /workspace/lora/lora.safetensors":

1. Confirm the collection was trained: check `collection.yaml` for non-null `artifacts.lora_gcs`
2. Check GCS: `gsutil ls gs://kalpa-assets/loras/oregon-coast/`
3. If the file is there, the pod may have had a GCS auth issue — check startup logs

### Video playback fails in browser (signed URL expired)

Signed URLs expire after 15 minutes. The web app regenerates the URL on each status
poll while `status === "complete"`, so this should only happen if the browser tab was
inactive for >15 minutes.

Reload the job page (`/job/{jobId}`) to trigger a fresh status poll and get a new URL.

---

## Script Reference

| Script | Run on | Purpose |
|--------|--------|---------|
| `scripts/setup-models.sh` | Mac | One-time: download LTX-2.3 weights from HF → GCS |
| `scripts/setup-models-remote.sh` | Mac | Download weights directly to a pod (alternative) |
| `scripts/train-runpod.sh` | Mac | Train a LoRA on RunPod H100 |
| `scripts/train-lambda.sh` | Mac | Train a LoRA on Lambda Labs H100 |
| `scripts/watch-and-train-runpod.sh` | Mac | Attach to a running RunPod training job |
| `scripts/watch-and-train-lambda.sh` | Mac | Attach to a running Lambda training job |
| `scripts/start-inference-runpod.sh` | Mac | Start inference server on RunPod A100 |
| `scripts/start-inference-lambda.sh` | Mac | Start inference server on Lambda Labs A100 |
| `scripts/stop-inference-runpod.sh` | Mac | Terminate RunPod inference instance |
| `scripts/stop-inference-lambda.sh` | Mac | Terminate Lambda Labs inference instance |
| `scripts/watch-and-infer-runpod.sh` | Mac | Tail logs of a running RunPod inference pod |
| `scripts/startup-train.sh` | H100 | Full training pipeline — boot script, not run manually |
| `scripts/startup-infer.sh` | A100 | Model download + FastAPI start — boot script, not run manually |
| `scripts/startup-setup.sh` | Pod | Common bootstrap (installs gcloud, uv, Node, Shelby CLI) |
| `scripts/logs.sh` | Mac | Tail logs for a named instance |
| `scripts/status.sh` | Mac | Show running instances |
| `scripts/kill.sh` | Mac | Force-terminate a named instance |
| `scripts/keep-instance.sh` | Mac | Prevent inactivity timeout on a named instance |
| `scripts/check-gpus-runpod.sh` | Mac | Check H100/A100 availability on RunPod |

---

## Updating Vercel Environment Variables

After starting a new inference pod, update `INFERENCE_SERVER_URL` in Vercel:

1. Go to your Vercel project → Settings → Environment Variables
2. Find `INFERENCE_SERVER_URL`
3. Update the value to `http://{new-pod-ip}:8080`
4. Redeploy is **not** required — Vercel picks up env var changes on the next request

Alternatively, use the Vercel CLI:
```bash
vercel env rm INFERENCE_SERVER_URL production
vercel env add INFERENCE_SERVER_URL production
# Enter the new URL when prompted
```
