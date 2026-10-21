"use client"

import { isLocalBuild, safeUrl, useRuntimeConfig } from "@/lib/runtime-config"

export function EnvValue() {
  const config = useRuntimeConfig()
  return <>{config?.ENV ?? "unknown"}</>
}

export function VersionValue() {
  const config = useRuntimeConfig()
  if (!config) return <>version unknown</>
  if (isLocalBuild(config)) {
    return <>local build (not built by CI)</>
  }
  const url = safeUrl(config.PIPELINE_URL)
  if (!url || url === "#") {
    return (
      <>
        v{config.VERSION} · build #{config.BUILD_NUMBER} · {config.GIT_BRANCH}@{config.GIT_COMMIT}
      </>
    )
  }
  return (
    <>
      v{config.VERSION} · build #{config.BUILD_NUMBER} · {config.GIT_BRANCH}@{config.GIT_COMMIT} ·{" "}
      <a
        href={url}
        target="_blank"
        rel="noopener noreferrer"
        title={url}
        className="underline decoration-white/20 hover:text-white/70 max-w-[220px] truncate inline-block align-bottom overflow-hidden text-ellipsis whitespace-nowrap"
      >
        pipeline
      </a>
    </>
  )
}
