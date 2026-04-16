import { createJob } from '@/lib/inference'
import { buildPaymentRequirements, verifyX402 } from '@/lib/x402'

// Price read from collection config — hardcoded for v1, parameterise in v2
const INFERENCE_PRICE_APT = Number(process.env.INFERENCE_PRICE_APT ?? '0.01')

export async function POST(request: Request) {
  const requirements = buildPaymentRequirements(INFERENCE_PRICE_APT)
  const payment = await verifyX402(request, requirements)

  if (!payment.valid) {
    return Response.json(
      { error: payment.error, paymentRequired: requirements },
      {
        status: 402,
        headers: { 'X-Payment-Required': JSON.stringify(requirements) },
      },
    )
  }

  const body = await request.json()
  const { collection, prompt, seed } = body

  if (!collection || typeof collection !== 'string') {
    return Response.json({ error: 'collection is required' }, { status: 400 })
  }
  if (!prompt || typeof prompt !== 'string' || prompt.trim().length === 0) {
    return Response.json({ error: 'prompt is required' }, { status: 400 })
  }

  try {
    const job = await createJob(collection, prompt.trim(), seed)
    return Response.json({ jobId: job.job_id }, { status: 201 })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Unknown error'
    // Inference server offline or overloaded
    if (message.includes('503') || message.includes('fetch failed')) {
      return Response.json({ error: 'Inference server is offline' }, { status: 503 })
    }
    return Response.json({ error: message }, { status: 500 })
  }
}
