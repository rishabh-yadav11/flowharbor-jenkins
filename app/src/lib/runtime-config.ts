"use client"

import { useEffect, useState } from "react"

export interface RuntimeConfig {
  ENV: string
  VERSION: string
  BUILD_NUMBER: string
  GIT_COMMIT: string
  GIT_BRANCH: string
  GIT_AUTHOR: string
  TIMESTAMP: string
  PIPELINE_URL: string
}

export function useRuntimeConfig(): RuntimeConfig | null {
  const [config, setConfig] = useState<RuntimeConfig | null>(null)

  useEffect(() => {
    const cfg = (window as unknown as { __RUNTIME_CONFIG__?: RuntimeConfig }).__RUNTIME_CONFIG__
    setConfig(cfg ?? null)
  }, [])

  return config
}
