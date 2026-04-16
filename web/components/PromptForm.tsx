'use client'

import { useTransition, useState } from 'react'
import { useRouter } from 'next/navigation'

interface PromptFormProps {
  collection: string
}

export default function PromptForm({ collection }: PromptFormProps) {
  const router = useRouter()
  // rendering-usetransition-loading: useTransition for non-urgent navigation
  const [isPending, startTransition] = useTransition()
  const [prompt, setPrompt] = useState('')
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!prompt.trim() || isPending) return
    setError(null)

    try {
      const res = await fetch('/api/inference', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ collection, prompt: prompt.trim() }),
      })

      if (res.status === 402) {
        const data = await res.json()
        // TODO: trigger X402 payment flow here, then retry with X-Payment header
        // For now, surface the requirement to the user
        setError(`Payment required: ${data.paymentRequired?.amount} ${data.paymentRequired?.asset}`)
        return
      }

      if (!res.ok) {
        const data = await res.json().catch(() => ({}))
        setError(data.error ?? 'Something went wrong.')
        return
      }

      const { jobId } = await res.json()
      startTransition(() => {
        router.push(`/job/${jobId}`)
      })
    } catch {
      setError('Could not reach the server.')
    }
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4 w-full max-w-xl">
      <div className="flex flex-col gap-1">
        <label htmlFor="prompt" className="text-xs text-zinc-400 font-mono uppercase tracking-wider">
          Prompt — collection: {collection}
        </label>
        <textarea
          id="prompt"
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          placeholder={`KALPA_COAST aerial coastline, dramatic cliffs…`}
          rows={4}
          disabled={isPending}
          className="bg-zinc-900 border border-zinc-700 rounded-lg px-4 py-3 text-zinc-100 text-sm
                     placeholder:text-zinc-600 focus:outline-none focus:border-indigo-500
                     resize-none disabled:opacity-50"
        />
      </div>

      {error !== null ? (
        <p className="text-red-400 text-sm">{error}</p>
      ) : null}

      <button
        type="submit"
        disabled={isPending || !prompt.trim()}
        className="bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed
                   text-white font-medium text-sm rounded-lg px-6 py-3 transition-colors"
      >
        {isPending ? 'Submitting…' : 'Generate'}
      </button>
    </form>
  )
}
