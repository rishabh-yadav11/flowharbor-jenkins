/** @vitest-environment jsdom */
import { renderHook, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { useRuntimeConfig } from "@/lib/runtime-config"

const w = window as unknown as { __RUNTIME_CONFIG__?: unknown }

afterEach(() => {
  delete w.__RUNTIME_CONFIG__
})

describe("useRuntimeConfig", () => {
  it("returns null when the boot script never ran", async () => {
    const { result } = renderHook(() => useRuntimeConfig())
    await waitFor(() => expect(result.current).toBeNull())
  })

  it("parses the injected config object", async () => {
    w.__RUNTIME_CONFIG__ = { ENV: "prod", VERSION: "1.2.3", BUILD_NUMBER: "42" }
    const { result } = renderHook(() => useRuntimeConfig())
    await waitFor(() => expect(result.current?.VERSION).toBe("1.2.3"))
    expect(result.current?.ENV).toBe("prod")
    expect(result.current?.BUILD_NUMBER).toBe("42")
  })

  it("returns null instead of throwing on an unparsable payload", async () => {
    w.__RUNTIME_CONFIG__ = { VERSION: "x".repeat(9000) }
    const { result } = renderHook(() => useRuntimeConfig())
    await waitFor(() => expect(result.current).toBeNull())
  })
})
