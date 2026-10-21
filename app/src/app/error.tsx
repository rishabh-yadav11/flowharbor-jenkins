"use client"

export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string }
  reset: () => void
}) {
  return (
    <main className="flex min-h-dvh flex-col items-center justify-center gap-6 bg-[#05060f] px-6 text-center text-white">
      <div className="max-w-md">
        <h1 className="text-2xl font-semibold tracking-tight">Something went wrong</h1>
        <p className="mt-3 text-sm text-red-300">
          {error.message || "An unexpected error stopped this page from rendering."}
        </p>
      </div>
      <button
        type="button"
        onClick={() => reset()}
        className="rounded-full border border-white/15 bg-white/5 px-5 py-2 text-sm font-medium text-white/80 transition hover:bg-white/10"
      >
        Reset
      </button>
    </main>
  )
}
