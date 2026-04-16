# Web App

The web app is a Next.js 15 app deployed to Vercel. It is the only public-facing surface
of the system. It handles user interaction, payment verification, job orchestration, and
video delivery.

Source: `web/`

---

## Pages

### `/` — Home

Shows the prompt form when the inference server is online, or an offline message when
it is not.

On mount, the page begins polling `GET /api/health` every 5s. Once the server reports
`status: "online"`, the prompt form is shown and polling stops.

**Components involved:**
- `app/page.tsx` — server component shell (no logic)
- `components/HomeClient.tsx` — client component, owns the polling loop and conditional rendering
- `components/PromptForm.tsx` — the textarea + submit button

### `/job/[jobId]` — Job Status

Shows real-time job progress and the completed video.

On mount, the page begins polling `GET /api/status/{jobId}` every 10s. Polling stops
when the job status is `complete` or `failed`.

**Components involved:**
- `app/job/[jobId]/page.tsx` — server component shell
- `components/JobPageClient.tsx` — client component, owns the polling loop and state transitions
- `components/VideoPlayer.tsx` — renders `<video>` element when a signed URL is available

---

## API Routes

### POST /api/inference

Accepts a generation request from the browser.

**Flow:**
```
1. Extract X402 payment header from request
2. If X402_ENFORCE=true:
     Verify payment via X402 facilitator
     If invalid: return 402 { price, payTo, network }
3. Generate a uuid job_id
4. POST http://{INFERENCE_SERVER_URL}/inference
     { job_id, collection, video_prompt }
     X-API-Key: INFERENCE_API_KEY
5. Return { jobId } to browser
```

**Request body:**
```json
{
  "prompt": "KALPA_COAST aerial coastline, dramatic cliffs"
}
```

**Response (success):**
```json
{
  "jobId": "abc123"
}
```

**Response (payment required, when X402_ENFORCE=true):**
```
HTTP 402
{
  "error": "Payment required",
  "price": "0.01",
  "currency": "APT",
  "payTo": "0x...",
  "network": "aptos:testnet"
}
```

Source: `web/app/api/inference/route.ts`, `web/lib/x402.ts`

---

### GET /api/health

Proxies to the inference server's `/health` endpoint.

**Response:**
```json
{
  "status": "online" | "loading" | "offline",
  "collection": "oregon-coast",
  "queue_depth": 0
}
```

`status: "offline"` is returned (by Vercel, not the inference server) when the inference
server is unreachable. This is the state when no pod is running.

Source: `web/app/api/health/route.ts`

---

### GET /api/status/[jobId]

Proxies to the inference server's `/status/:id` endpoint. When the job is complete,
generates a signed GCS URL for video playback.

**Response (pending/running):**
```json
{
  "status": "pending" | "running"
}
```

**Response (complete):**
```json
{
  "status": "complete",
  "videoUrl": "https://storage.googleapis.com/kalpa-assets/outputs/oregon-coast/abc123.mp4?X-Goog-Signature=...",
  "shelbyVideo": "outputs/oregon-coast/abc123.mp4",
  "shelbyMetadata": "outputs/oregon-coast/abc123-metadata.json"
}
```

`videoUrl` is a signed URL with a 15-minute expiry. The browser uses this directly
in the `<video>` element. It is regenerated on each poll when status is complete.

Source: `web/app/api/status/[jobId]/route.ts`, `web/lib/gcs.ts`

---

## X402 Integration

Payment verification is implemented in `web/lib/x402.ts` and used by
`/api/inference/route.ts`.

**Current state:** `X402_ENFORCE=false` — the payment check is skipped entirely.
All inference requests pass through without a payment header.

**Target state:** When `X402_ENFORCE=true`:
1. The route checks for an `X-PAYMENT` header on the request
2. If missing: returns HTTP 402 with payment requirements
3. The browser's wallet signs the payment and retries with the header
4. The route calls the X402 facilitator to verify the payment
5. If valid: proceeds to queue the job

The `@x402/next` package is installed but the verification logic is currently a
placeholder. `web/lib/x402.ts` is where the real implementation will live.

**Environment variables for X402:**

| Variable | Purpose |
|----------|---------|
| `X402_ENFORCE` | `true` to require payment, `false` (default) to skip |
| `X402_FACILITATOR_URL` | X402 facilitator endpoint for payment verification |
| `X402_PAYTO_ADDRESS` | Aptos wallet address that receives inference payments |
| `X402_NETWORK` | Default: `aptos:testnet` |
| `INFERENCE_PRICE_APT` | Price per inference job (default: `0.01` APT) |

---

## GCS Signed URLs

`web/lib/gcs.ts` uses the `@google-cloud/storage` Node.js SDK to generate signed URLs.
The service account JSON (`GCP_SA_KEY` env var) has `storage.objectViewer` permissions
on the `kalpa-assets` bucket.

```typescript
// Converts gs://kalpa-assets/outputs/... to a signed HTTPS URL
const url = await generateSignedUrl({
  bucket: process.env.GCS_BUCKET!,   // without gs:// prefix
  object: gcsPath,
  expiresIn: 15 * 60,                 // 15 minutes
})
```

Signed URLs are generated fresh on each status poll once the job is complete. This
prevents the URL from expiring if the user lingers on the job page.

---

## Polling Behavior

| Endpoint | Interval | Stops when |
|----------|----------|-----------|
| `GET /api/health` | 5s | `status === "online"` |
| `GET /api/status/:id` | 10s | `status === "complete"` or `status === "failed"` |

Both polling loops are implemented with `setInterval` in client components and clean
up their timers on unmount.

SWR is listed as a dependency but is not used for the polling loops — the intervals
are managed with raw `setInterval` in `HomeClient.tsx` and `JobPageClient.tsx`.

---

## Environment Variables

Set in `web/.env.local` for local development, and in the Vercel project settings for
production.

| Variable | Required | Description |
|----------|----------|-------------|
| `INFERENCE_SERVER_URL` | ✅ | Full URL of inference server: `http://{pod-ip}:8080`. Update this each time you start a new inference pod. |
| `INFERENCE_API_KEY` | ✅ | Shared secret. Must match the value the inference pod was started with. |
| `GCP_PROJECT_ID` | ✅ | GCP project ID (for signed URL generation) |
| `GCP_SA_KEY` | ✅ | Full contents of the Vercel service account JSON key, as a single-line string |
| `GCS_BUCKET` | ✅ | Bucket name **without** `gs://` prefix (e.g. `kalpa-assets`) |
| `INFERENCE_PRICE_APT` | ❌ | Price per inference in APT. Default: `0.01` |
| `X402_ENFORCE` | ❌ | Set to `true` to require payment. Default: `false` |
| `X402_FACILITATOR_URL` | ❌ | X402 facilitator endpoint |
| `X402_PAYTO_ADDRESS` | ❌ | Aptos wallet address receiving inference payments |
| `X402_NETWORK` | ❌ | Default: `aptos:testnet` |

---

## Component Reference

| File | Type | Purpose |
|------|------|---------|
| `app/page.tsx` | Server | Home page shell |
| `app/job/[jobId]/page.tsx` | Server | Job page shell |
| `app/layout.tsx` | Server | Root layout (fonts, metadata) |
| `app/globals.css` | — | Tailwind + dark theme variables |
| `components/HomeClient.tsx` | Client | Health polling, conditional prompt/offline rendering |
| `components/PromptForm.tsx` | Client | Prompt textarea, submit handler, redirect to `/job/:id` |
| `components/JobPageClient.tsx` | Client | Status polling, progress display, triggers video player |
| `components/VideoPlayer.tsx` | Client | `<video>` element + Shelby blob link |
| `app/api/health/route.ts` | API | Proxy to inference `/health` |
| `app/api/inference/route.ts` | API | X402 check + job creation |
| `app/api/status/[jobId]/route.ts` | API | Status proxy + signed URL generation |
| `lib/inference.ts` | Lib | Typed client for inference server HTTP calls |
| `lib/x402.ts` | Lib | X402 payment verification (placeholder) |
| `lib/gcs.ts` | Lib | GCS signed URL generation |

---

## Local Development

```bash
cd web
cp .env.local.example .env.local
# Fill in .env.local

pnpm install
pnpm dev
```

The web app will start at `http://localhost:3000`. With `X402_ENFORCE=false` (default),
you can generate videos without a wallet. The inference server must be running and
`INFERENCE_SERVER_URL` must point to it.

To test against a RunPod inference pod, set `INFERENCE_SERVER_URL` in `.env.local` to
the pod's IP before starting `pnpm dev`.

---

## Deploying to Vercel

```bash
cd web
vercel deploy
```

After deploying, update all environment variables in Vercel project settings
(Settings → Environment Variables). The `INFERENCE_SERVER_URL` must be updated
each time a new inference pod is started.
