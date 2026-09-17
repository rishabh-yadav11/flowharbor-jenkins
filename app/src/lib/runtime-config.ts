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
const MAX_TOTAL_LEN = 8192

const ALLOWED_ENVS = new Set(["dev", "staging", "prod"])

// Serialize for embedding in <script> (external or inlined). JSON.stringify
// does NOT escape `<`, `>`, U+2028/29, so `</script>` would break out if the
// file is ever inlined. Escape to \u003c/\u003e/\u2028/\u2029 (issue #20).
export function serializeRuntimeConfig(cfg: RuntimeConfig): string {
  return JSON.stringify(cfg)
    .replace(/</g, "\\u003c")
    .replace(/>/g, "\\u003e")
    .replace(/\u2028/g, "\\u2028")
    .replace(/\u2029/g, "\\u2029")
}

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
  if (typeof v !== "string") return fallback
  const s = v.slice(0, n)
  return s || fallback
}

function capAuthor(v: unknown): string {
  if (typeof v !== "string") return "unknown"
  const s = v.replace(/[\r\n]+/g, " ").slice(0, MAX_AUTHOR_LEN).trim()
  return s || "unknown"
}

export function parseRuntimeConfig(raw: unknown): RuntimeConfig {
  if (typeof raw === "string" && raw.length > MAX_TOTAL_LEN) {
    throw new Error("runtime-config oversize")
  }
  try {
    if (raw != null && JSON.stringify(raw).length > MAX_TOTAL_LEN) {
      throw new Error("runtime-config oversize")
    }
  } catch (e) {
    if (e instanceof Error && e.message === "runtime-config oversize") throw e
  }
  const r = (raw ?? {}) as Record<string, unknown>
  const envRaw = typeof r.ENV === "string" ? r.ENV : "dev"
  const cfg: RuntimeConfig = {
    ENV: ALLOWED_ENVS.has(envRaw) ? envRaw : "dev",
    VERSION: cap(r.VERSION, MAX_SHORT_LEN, "1.0.0"),
    BUILD_NUMBER: cap(r.BUILD_NUMBER, MAX_SHORT_LEN, "0"),
    GIT_COMMIT: cap(r.GIT_COMMIT, MAX_SHORT_LEN, "unknown"),
    GIT_BRANCH: cap(r.GIT_BRANCH, MAX_SHORT_LEN, "unknown"),
    GIT_AUTHOR: capAuthor(r.GIT_AUTHOR),
    TIMESTAMP: cap(r.TIMESTAMP, MAX_SHORT_LEN, "unknown"),
    PIPELINE_URL: safeUrl(r.PIPELINE_URL) ?? "#",
  }
  return Object.freeze(cfg) as RuntimeConfig
}

export function useRuntimeConfig(): RuntimeConfig | null {
  const [config, setConfig] = useState<RuntimeConfig | null>(null)

  useEffect(() => {
    const w = window as unknown as { __RUNTIME_CONFIG__?: unknown }
    const cfg = w.__RUNTIME_CONFIG__
    if (cfg == null) {
      setConfig(null)
      return
    }
    try {
      // Best-effort freeze so third-party scripts cannot mutate before parse.
      if (typeof cfg === "object" && cfg !== null) Object.freeze(cfg)
      setConfig(parseRuntimeConfig(cfg))
    } catch {
      setConfig(null)
    }
  }, [])

  return config
}
