import { ParticleField } from "@/components/particle-field"
import { EnvValue, VersionValue } from "@/components/runtime-badges"

export default function Home() {
  return (
    <main className="relative min-h-dvh overflow-hidden bg-[#05060f] text-white">
      <ParticleField />

      {/* Vignette + grain overlay for depth */}
      <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(ellipse_at_center,transparent_35%,rgba(0,0,0,0.55)_100%)]" />
      <div
        className="pointer-events-none absolute inset-0 opacity-[0.035]"
        style={{
          backgroundImage:
            "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='120'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='3'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\")",
        }}
      />

      {/* Top bar with env badge */}
      <div className="absolute inset-x-0 top-0 flex items-center justify-between p-5">
        <span className="text-sm font-semibold tracking-widest text-white/70 uppercase">
          FlowHarbor
        </span>
        <span className="inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/5 px-3 py-1 text-xs font-medium text-white/70 backdrop-blur-md">
          <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-emerald-400" />
          env: <EnvValue />
        </span>
      </div>

      {/* Hero */}
      <div className="relative z-10 flex min-h-dvh flex-col items-center justify-center px-6 text-center">
        <h1 className="bg-gradient-to-br from-white via-indigo-200 to-indigo-400 bg-clip-text text-6xl font-black tracking-tight text-transparent sm:text-8xl">
          FlowHarbor
        </h1>
        <p className="mt-5 max-w-md text-base text-white/50 sm:text-lg">
          Every commit, every tag, a flawless release. Built to move. tools
        </p>
      </div>

      {/* Bottom metadata */}
      <div className="absolute inset-x-0 bottom-0 flex flex-col items-center gap-2 p-6 text-xs text-white/40">
        <p className="tabular-nums">
          <VersionValue />
        </p>
        <p className="text-white/30">Click anywhere — the field follows you</p>
      </div>
    </main>
  )
}
