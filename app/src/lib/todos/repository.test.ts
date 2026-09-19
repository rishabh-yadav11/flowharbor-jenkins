import { afterEach, describe, expect, it, vi } from "vitest"

// Dynamic import on purpose: each case needs a fresh module instance so the
// process-level repository singleton and DATA_BACKEND are re-evaluated.
async function freshRepository() {
  vi.resetModules()
  return import("@/lib/todos/repository")
}

afterEach(() => {
  vi.unstubAllEnvs()
  vi.resetModules()
})

describe("getRepository", () => {
  it("uses the in-memory store when DATA_BACKEND is unset", async () => {
    const { getRepository } = await freshRepository()
    expect(await getRepository().list()).toHaveLength(3)
  })

  it("returns the same instance on every call", async () => {
    const { getRepository } = await freshRepository()
    expect(getRepository()).toBe(getRepository())
  })

  it("refuses dynamodb without a table name", async () => {
    vi.stubEnv("DATA_BACKEND", "dynamodb")
    vi.stubEnv("TODO_TABLE", "")
    const { getRepository } = await freshRepository()
    expect(() => getRepository()).toThrow("DATA_BACKEND=dynamodb requires TODO_TABLE")
  })

  it("builds a dynamodb repository when the table name is set", async () => {
    vi.stubEnv("DATA_BACKEND", "dynamodb")
    vi.stubEnv("TODO_TABLE", "flowharbor-todos")
    const { getRepository } = await freshRepository()
    expect(typeof getRepository().create).toBe("function")
  })
})

describe("pingDatabase", () => {
  it("reports the in-memory backend as healthy", async () => {
    const { pingDatabase } = await freshRepository()
    expect(await pingDatabase()).toEqual({ ok: true, detail: "in-memory" })
  })

  it("reports a missing table name instead of throwing", async () => {
    vi.stubEnv("DATA_BACKEND", "dynamodb")
    vi.stubEnv("TODO_TABLE", "")
    const { pingDatabase } = await freshRepository()
    expect(await pingDatabase()).toEqual({ ok: false, detail: "TODO_TABLE is not set" })
  })

  it("reports an unreachable dynamodb as unhealthy instead of throwing", async () => {
    vi.stubEnv("DATA_BACKEND", "dynamodb")
    vi.stubEnv("TODO_TABLE", "flowharbor-todos")
    // No credentials and no IMDS: the SDK must fail fast rather than hang.
    vi.stubEnv("AWS_REGION", "us-east-1")
    vi.stubEnv("AWS_EC2_METADATA_DISABLED", "true")
    vi.stubEnv("AWS_MAX_ATTEMPTS", "1")
    const { pingDatabase } = await freshRepository()
    const status = await pingDatabase()
    expect(status.ok).toBe(false)
    expect(status.detail).not.toBe("in-memory")
  }, 20000)
})
