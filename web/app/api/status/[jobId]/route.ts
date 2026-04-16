import { fetchJobStatus } from '@/lib/inference'
import { signedUrl } from '@/lib/gcs'

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ jobId: string }> },
) {
  const { jobId } = await params

  try {
    const job = await fetchJobStatus(jobId)

    // When complete, attach a signed GCS URL for the video player.
    // The Shelby blob is also returned for the demo narrative / X402 display.
    if (job.status === 'complete' && job.gcs_path) {
      const videoUrl = await signedUrl(job.gcs_path)
      return Response.json({ ...job, videoUrl })
    }

    return Response.json(job)
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Unknown error'
    if (message.includes('404')) {
      return Response.json({ error: 'Job not found' }, { status: 404 })
    }
    return Response.json({ error: message }, { status: 500 })
  }
}
