// Server Component shell — client handles SWR polling
import JobPageClient from '@/components/JobPageClient'
import Link from 'next/link'

export default async function JobPage({
  params,
}: {
  params: Promise<{ jobId: string }>
}) {
  const { jobId } = await params

  return (
    <main className="flex min-h-screen flex-col items-center justify-center px-4 py-16 gap-10">
      <div className="flex flex-col items-center gap-2 text-center">
        <Link href="/" className="text-zinc-600 hover:text-zinc-400 text-xs transition-colors">
          ← back
        </Link>
        <h1 className="text-xl font-semibold tracking-tight">Generation</h1>
        <p className="text-zinc-600 text-xs font-mono">{jobId}</p>
      </div>
      <JobPageClient jobId={jobId} />
    </main>
  )
}
