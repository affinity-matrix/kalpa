'use client'

interface VideoPlayerProps {
  src: string
  shelbyBlob: string | null
}

export default function VideoPlayer({ src, shelbyBlob }: VideoPlayerProps) {
  return (
    <div className="flex flex-col gap-3">
      <video
        src={src}
        controls
        autoPlay
        loop
        playsInline
        className="w-full rounded-lg bg-black"
        style={{ maxHeight: '60vh' }}
      />
      {shelbyBlob !== null ? (
        <p className="text-xs text-zinc-500 font-mono break-all">
          shelby://{shelbyBlob}
        </p>
      ) : null}
    </div>
  )
}
