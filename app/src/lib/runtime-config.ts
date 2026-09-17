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

const MAX_URL_LEN = 2048
const MAX_SHORT_LEN = 128
const MAX_AUTHOR_LEN = 256

export function safeUrl(raw: unknown): string | null {
  if (typeof raw !== "string") return null
  const v = raw.trim().slice(0, MAX_URL_LEN)
  if (!v || v === "#") return "#"
  // Reject control chars / embedded whitespace (bypass: "  javascript:\n...")
  if (/[\u0000-\u0020\u007F]/.test(v)) return null
  let u: URL
  try {
    u = new URL(v)
  } catch {
    return null
  }
  const proto = u.protocol.toLowerCase()
  if (proto !== "http:" && proto !== "https:") return null
  return u.toString().slice(0, MAX_URL_LEN)
}

function cap(v: unknown, n: number, fallback: string): string {
  const s = String(v ?? fallback).slice(0, n)
  return s || fallback
}

export function parseRuntimeConfig(raw: unknown): RuntimeConfig {
  const r = (raw ?? {}) as Record<string, unknown>
  const cfg: RuntimeConfig = {
    ENV: cap(r.ENV, MAX_SHORT_LEN, "dev"),
    VERSION: cap(r.VERSION, MAX_SHORT_LEN, "1.0.0"),
    BUILD_NUMBER: cap(r.BUILD_NUMBER, MAX_SHORT_LEN, "0"),
    GIT_COMMIT: cap(r.GIT_COMMIT, MAX_SHORT_LEN, "unknown"),
    GIT_BRANCH: cap(r.GIT_BRANCH, MAX_SHORT_LEN, "unknown"),
    GIT_AUTHOR: cap(r.GIT_AUTHOR, MAX_AUTHOR_LEN, "unknown"),
    TIMESTAMP: cap(r.TIMESTAMP, MAX_SHORT_LEN, "unknown"),
    PIPELINE_URL: safeUrl(r.PIPELINE_URL) ?? "#",
  }
  return Object.freeze(cfg) as RuntimeConfig
}

export function useRuntimeConfig(): RuntimeConfig | null {
  const [config, setConfig] = useState<RuntimeConfig | null>(null)

  useEffect(() => {
    const cfg = (window as unknown as { __RUNTIME_CONFIG__?: unknown }).__RUNTIME_CONFIG__
    if (cfg == null) {
      setConfig(null)
      return
    }
    try {
      setConfig(parseRuntimeConfig(cfg))
    } catch {
      setConfig(null)
    }
  }, [])

  return config
}
