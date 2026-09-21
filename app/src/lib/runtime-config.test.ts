import { describe, expect, it } from "vitest"
import { parseRuntimeConfig, safeUrl, serializeRuntimeConfig } from "@/lib/runtime-config"

const base = {
  ENV: "dev",
  VERSION: "1.0.0",
  BUILD_NUMBER: "0",
  GIT_COMMIT: "unknown",
  GIT_BRANCH: "unknown",
  GIT_AUTHOR: "unknown",
  TIMESTAMP: "unknown",
  PIPELINE_URL: "#",
}

describe("serializeRuntimeConfig", () => {
  it("escapes angle brackets so </script> cannot break out", () => {
    const out = serializeRuntimeConfig({ ...base, GIT_AUTHOR: "</script><script>alert(1)</script>" })
    expect(out).not.toContain("<")
    expect(out).not.toContain(">")
    expect(out).toContain("\\u003c/script\\u003e")
  })

  it("escapes U+2028 and U+2029 line separators", () => {
    const out = serializeRuntimeConfig({ ...base, GIT_AUTHOR: "a\u2028b\u2029c" })
    expect(out).toContain("\\u2028")
    expect(out).toContain("\\u2029")
  })
})

describe("safeUrl", () => {
  it("rejects javascript: URLs", () => {
    expect(safeUrl("javascript:alert(1)")).toBeNull()
  })

  it("rejects embedded control characters and whitespace", () => {
    expect(safeUrl("http://example.com/\njavascript:alert(1)")).toBeNull()
  })

  it('collapses a blank value to the "#" placeholder', () => {
    expect(safeUrl("   ")).toBe("#")
  })

  it("rejects non-strings", () => {
    expect(safeUrl(42)).toBeNull()
    expect(safeUrl(null)).toBeNull()
  })

  it('returns "#" for the placeholder and an absolute URL for http(s)', () => {
    expect(safeUrl("#")).toBe("#")
    expect(safeUrl("https://jenkins.example.com/job/1/")).toBe("https://jenkins.example.com/job/1/")
  })
})

describe("parseRuntimeConfig", () => {
  it("fills defaults for missing keys", () => {
    expect(parseRuntimeConfig({})).toEqual(base)
  })

  it('falls back to env "dev" for an unknown ENV', () => {
    expect(parseRuntimeConfig({ ENV: "bogus" }).ENV).toBe("dev")
    expect(parseRuntimeConfig({ ENV: "prod" }).ENV).toBe("prod")
  })

  it('neutralises a hostile PIPELINE_URL to "#"', () => {
    expect(parseRuntimeConfig({ PIPELINE_URL: "javascript:alert(1)" }).PIPELINE_URL).toBe("#")
  })

  it("flattens newlines in GIT_AUTHOR", () => {
    expect(parseRuntimeConfig({ GIT_AUTHOR: "a\nb" }).GIT_AUTHOR).toBe("a b")
  })

  it("throws runtime-config oversize for an oversized string payload", () => {
    expect(() => parseRuntimeConfig("x".repeat(9000))).toThrow("runtime-config oversize")
  })

  it("throws runtime-config oversize for an oversized object payload", () => {
    expect(() => parseRuntimeConfig({ VERSION: "x".repeat(9000) })).toThrow(
      "runtime-config oversize"
    )
  })

  it("freezes the returned config", () => {
    const cfg = parseRuntimeConfig({})
    expect(Object.isFrozen(cfg)).toBe(true)
  })
})
