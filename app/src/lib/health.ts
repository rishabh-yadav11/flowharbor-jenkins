const ALLOWED_ENVS = new Set(["dev", "staging", "prod"])

export interface HealthPayload {
  status: "ok" | "degraded"
  env: string
  version: string
  build: string
  commit: string
  checks: {
    database: { ok: boolean; detail: string }
  }
}

const orUnknown = (v: string | undefined): string => {
  const s = (v ?? "").trim()
  return s || "unknown"
}

export function buildHealthPayload(
  env: Record<string, string | undefined>,
  database: { ok: boolean; detail: string }
): HealthPayload {
  const rawEnv = (env.ENV ?? "").trim()
  return {
    status: database.ok ? "ok" : "degraded",
    env: ALLOWED_ENVS.has(rawEnv) ? rawEnv : "dev",
    version: orUnknown(env.VERSION),
    build: orUnknown(env.BUILD_NUMBER),
    commit: orUnknown(env.GIT_COMMIT),
    checks: { database },
  }
}
