import { fetchHealth } from '@/lib/inference'

export async function GET() {
  try {
    const health = await fetchHealth()
    return Response.json(health)
  } catch {
    return Response.json({ status: 'offline', collection: null, queue_depth: 0 }, { status: 503 })
  }
}
