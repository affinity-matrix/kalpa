/**
 * Typed client for the Kalpa inference server.
 * Used by both API routes (server-side) and optionally client components.
 */

const INFERENCE_SERVER_URL = process.env.INFERENCE_SERVER_URL!
const INFERENCE_API_KEY = process.env.INFERENCE_API_KEY!

export type ServerStatus = 'online' | 'loading' | 'offline'

export interface HealthResponse {
  status: ServerStatus
  collection: string
  queue_depth: number
}

export type JobStatus = 'pending' | 'running' | 'complete' | 'failed'

export interface JobResponse {
  job_id: string
  status: JobStatus
  collection: string
  prompt: string
  gcs_path: string | null
  shelby_blob: string | null
  error: string | null
  created_at: string
  completed_at: string | null
}

function authHeaders(): HeadersInit {
  return { 'X-API-Key': INFERENCE_API_KEY, 'Content-Type': 'application/json' }
}

export async function fetchHealth(): Promise<HealthResponse> {
  const res = await fetch(`${INFERENCE_SERVER_URL}/health`, {
    headers: authHeaders(),
    next: { revalidate: 0 },
  })
  if (!res.ok) throw new Error(`Health check failed: ${res.status}`)
  return res.json()
}

export async function createJob(
  collection: string,
  prompt: string,
  seed?: number,
): Promise<{ job_id: string }> {
  const res = await fetch(`${INFERENCE_SERVER_URL}/inference`, {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify({ collection, prompt, seed }),
  })
  if (!res.ok) {
    const err = await res.json().catch(() => ({}))
    throw new Error(err.detail ?? `Inference request failed: ${res.status}`)
  }
  return res.json()
}

export async function fetchJobStatus(jobId: string): Promise<JobResponse> {
  const res = await fetch(`${INFERENCE_SERVER_URL}/status/${jobId}`, {
    headers: authHeaders(),
    next: { revalidate: 0 },
  })
  if (!res.ok) throw new Error(`Status check failed: ${res.status}`)
  return res.json()
}
