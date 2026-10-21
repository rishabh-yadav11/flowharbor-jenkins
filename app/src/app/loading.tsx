export default function Loading() {
  return (
    <main className="flex min-h-dvh items-center justify-center bg-[#05060f] text-white">
      <div className="flex items-center gap-3 text-sm font-medium tracking-wide text-white/50">
        <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-emerald-400" />
        Loading...
      </div>
    </main>
  )
}
