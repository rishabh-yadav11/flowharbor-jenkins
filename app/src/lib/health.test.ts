import { describe, expect, it } from "vitest"
import { buildHealthPayload } from "@/lib/health"

const ok = { ok: true, detail: "in-memory" }
const down = { ok: false, detail: "dynamodb:todos is CREATING" }

describe("buildHealthPayload", () => {
  it("is ok only when the database check passes", () => {
    expect(buildHealthPayload({}, ok).status).toBe("ok")
    expect(buildHealthPayload({}, down).status).toBe("degraded")
  })

  it('falls back to env "dev" unless it is dev, staging, or prod', () => {
    expect(buildHealthPayload({ ENV: "prod" }, ok).env).toBe("prod")
    expect(buildHealthPayload({ ENV: "staging" }, ok).env).toBe("staging")
    expect(buildHealthPayload({ ENV: "qa" }, ok).env).toBe("dev")
    expect(buildHealthPayload({ ENV: "  " }, ok).env).toBe("dev")
  })

  it('reports "unknown" for missing version, build, and commit', () => {
    const payload = buildHealthPayload({}, ok)
    expect(payload.version).toBe("unknown")
    expect(payload.build).toBe("unknown")
    expect(payload.commit).toBe("unknown")
  })

  it("passes the build metadata through", () => {
    const payload = buildHealthPayload(
      { VERSION: "1.2.3", BUILD_NUMBER: "42", GIT_COMMIT: "abc1234" },
      ok
    )
    expect(payload.version).toBe("1.2.3")
    expect(payload.build).toBe("42")
    expect(payload.commit).toBe("abc1234")
  })

  it("surfaces the database detail verbatim", () => {
    expect(buildHealthPayload({}, down).checks.database).toEqual(down)
  })
})
