"use client"

import { useRuntimeConfig } from "@/lib/runtime-config"

export function EnvValue() {
  const config = useRuntimeConfig()
  return <>{config?.ENV ?? "unknown"}</>
}

export function VersionValue() {
  const config = useRuntimeConfig()
  if (!config) return <>version unknown</>
  return (
    <>
      v{config.VERSION} · build #{config.BUILD_NUMBER} · {config.GIT_BRANCH}@{config.GIT_COMMIT} ·{" "}
      <a
        href={config.PIPELINE_URL}
        target="_blank"
        rel="noopener noreferrer"
        className="underline decoration-white/20 hover:text-white/70"
      >
        pipeline
      </a>
    </>
  )
}
