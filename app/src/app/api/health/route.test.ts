import { beforeEach, describe, expect, it, vi } from "vitest"

// vi.hoisted: the factory is hoisted above the imports below.
const { pingDatabase } = vi.hoisted(() => ({ pingDatabase: vi.fn() }))
vi.mock("@/lib/todos/repository", () => ({ pingDatabase }))

import { GET } from "@/app/api/health/route"

beforeEach(() => {
  vi.clearAllMocks()
  vi.stubEnv("ENV", "prod")
  vi.stubEnv("VERSION", "1.2.3")
  vi.stubEnv("BUILD_NUMBER", "42")
  vi.stubEnv("GIT_COMMIT", "abc1234")
})

describe("GET /api/health", () => {
  it("returns 200 with a no-store header when the database check passes", async () => {
    pingDatabase.mockResolvedValueOnce({ ok: true, detail: "dynamodb:flowharbor-todos" })
    const res = await GET()

    expect(res.status).toBe(200)
    expect(res.headers.get("Cache-Control")).toBe("no-store")
    await expect(res.json()).resolves.toEqual({
      status: "ok",
      env: "prod",
      version: "1.2.3",
      build: "42",
      commit: "abc1234",
      checks: { database: { ok: true, detail: "dynamodb:flowharbor-todos" } },
    })
  })

  it("returns 503 with degraded status when the database is unreachable", async () => {
    pingDatabase.mockResolvedValueOnce({ ok: false, detail: "connect ETIMEDOUT" })
    const res = await GET()

    expect(res.status).toBe(503)
    const body = await res.json()
    expect(body.status).toBe("degraded")
    expect(body.checks.database.detail).toBe("connect ETIMEDOUT")
  })

  it("degrades instead of throwing when the probe itself throws", async () => {
    pingDatabase.mockRejectedValueOnce(new Error("aborted"))
    const res = await GET()

    expect(res.status).toBe(503)
    await expect(res.json()).resolves.toMatchObject({
      status: "degraded",
      checks: { database: { detail: "aborted" } },
    })
  })

  it('reports env "dev" when ENV is not one of dev/staging/prod', async () => {
    vi.stubEnv("ENV", "bogus")
    pingDatabase.mockResolvedValueOnce({ ok: true, detail: "in-memory" })
    const res = await GET()
    await expect(res.json()).resolves.toMatchObject({ env: "dev" })
  })
})
