'use client'

import dynamic from 'next/dynamic'
import useSWR from 'swr'

// bundle-dynamic-imports: VideoPlayer is only needed when job is complete
const VideoPlayer = dynamic(() => import('@/components/VideoPlayer'), { ssr: false })

interface JobPageClientProps {
  jobId: string
}

interface JobData {
  status: 'pending' | 'running' | 'complete' | 'failed'
  prompt: string
  videoUrl?: string
  shelby_blob: string | null
  error: string | null
  created_at: string
  completed_at: string | null
}

async function fetcher(url: string): Promise<JobData> {
  const res = await fetch(url)
  if (!res.ok) throw new Error('Failed to fetch job status')
  return res.json()
}

const STATUS_LABELS: Record<string, string> = {
  pending: 'Queued',
  running: 'Generating',
  complete: 'Complete',
  failed: 'Failed',
}

export default function JobPageClient({ jobId }: JobPageClientProps) {
  // client-swr-dedup: SWR deduplicates concurrent requests automatically.
  // rerender-derived-state: refreshInterval as a function — stops polling when done.
  const { data: job, error } = useSWR(`/api/status/${jobId}`, fetcher, {
    refreshInterval: (data) =>
      data?.status === 'complete' || data?.status === 'failed' ? 0 : 10_000,
  })

  const isComplete = job?.status === 'complete'
  const isFailed = job?.status === 'failed'
  const isDone = isComplete || isFailed

  const elapsed =
    job?.created_at
      ? Math.round((Date.now() - new Date(job.created_at).getTime()) / 1000)
      : 0

  if (error) {
    return (
      <div className="text-red-400 text-sm">
        Could not fetch job status. The inference server may be offline.
      </div>
    )
  }

  if (!job) {
    return <div className="text-zinc-400 text-sm animate-pulse">Loading…</div>
  }

  return (
    <div className="flex flex-col gap-6 w-full max-w-2xl">
      <div className="flex items-center justify-between">
        <span
          className={[
            'text-sm font-mono px-2 py-0.5 rounded',
            isComplete ? 'bg-green-900 text-green-300' :
            isFailed   ? 'bg-red-900 text-red-300' :
                         'bg-zinc-800 text-zinc-400',
          ].join(' ')}
        >
          {STATUS_LABELS[job.status] ?? job.status}
        </span>
        {!isDone ? (
          <span className="text-zinc-500 text-xs">{elapsed}s elapsed</span>
        ) : null}
      </div>

      <p className="text-zinc-300 text-sm italic">"{job.prompt}"</p>

      {isComplete && job.videoUrl ? (
        <VideoPlayer src={job.videoUrl} shelbyBlob={job.shelby_blob} />
      ) : null}

      {isFailed ? (
        <p className="text-red-400 text-sm">{job.error ?? 'Generation failed.'}</p>
      ) : null}

      {!isDone ? (
        <div className="flex flex-col gap-2">
          <div className="h-1 bg-zinc-800 rounded overflow-hidden">
            <div className="h-full bg-indigo-500 animate-pulse w-1/3 rounded" />
          </div>
          <p className="text-zinc-500 text-xs">
            Inference takes ~8–12 min. This page polls automatically.
          </p>
        </div>
      ) : null}
    </div>
  )
}
