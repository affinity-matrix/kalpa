'use client'

import useSWR from 'swr'
import PromptForm from '@/components/PromptForm'

interface HealthData {
  status: 'online' | 'loading' | 'offline'
  collection: string
  queue_depth: number
}

async function fetcher(url: string): Promise<HealthData> {
  const res = await fetch(url)
  return res.json()
}

export default function HomeClient() {
  // client-swr-dedup: polls every 5s when offline, stops when online
  const { data: health } = useSWR('/api/health', fetcher, {
    refreshInterval: (data) => (data?.status === 'online' ? 0 : 5_000),
  })

  if (!health) {
    return <p className="text-zinc-500 text-sm animate-pulse">Checking server…</p>
  }

  if (health.status !== 'online') {
    return (
      <div className="flex flex-col gap-3 text-center">
        <div className="inline-flex items-center gap-2 text-yellow-400 text-sm">
          <span className="w-2 h-2 rounded-full bg-yellow-400 animate-pulse" />
          Demo is offline
        </div>
        <p className="text-zinc-500 text-xs max-w-sm">
          Run{' '}
          <code className="bg-zinc-800 px-1 rounded font-mono">
            ./scripts/start-inference.sh --collection oregon-coast
          </code>{' '}
          to bring it up. This page will update automatically.
        </p>
        {health.status === 'loading' ? (
          <p className="text-zinc-600 text-xs">Model is loading into GPU memory…</p>
        ) : null}
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-6 items-center">
      <div className="inline-flex items-center gap-2 text-green-400 text-xs font-mono">
        <span className="w-2 h-2 rounded-full bg-green-400" />
        online
        {health.queue_depth > 0 ? (
          <span className="text-zinc-500">· {health.queue_depth} in queue</span>
        ) : null}
      </div>
      <PromptForm collection={health.collection} />
    </div>
  )
}
