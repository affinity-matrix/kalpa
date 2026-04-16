// Server Component — renders shell instantly, HomeClient handles polling
import HomeClient from '@/components/HomeClient'

export default function HomePage() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center px-4 py-16 gap-12">
      <div className="flex flex-col items-center gap-2 text-center">
        <h1 className="text-3xl font-semibold tracking-tight">Kalpa</h1>
        <p className="text-zinc-500 text-sm">
          Style LoRA · LTX-2.3 · Shelby Protocol
        </p>
      </div>
      <HomeClient />
    </main>
  )
}
