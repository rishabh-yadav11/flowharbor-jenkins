/** @vitest-environment jsdom */
import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { EnvValue, VersionValue } from "@/components/runtime-badges"

const w = window as unknown as { __RUNTIME_CONFIG__?: unknown }

afterEach(() => {
  delete w.__RUNTIME_CONFIG__
  cleanup()
})

describe("EnvValue", () => {
  it('shows "unknown" until the boot config arrives', () => {
    render(<EnvValue />)
    expect(screen.getByText("unknown")).toBeInTheDocument()
  })

  it("shows the injected environment", () => {
    w.__RUNTIME_CONFIG__ = { ENV: "staging" }
    render(<EnvValue />)
    expect(screen.getByText("staging")).toBeInTheDocument()
  })
})

describe("VersionValue", () => {
  it('renders "version unknown" without runtime config', () => {
    render(<VersionValue />)
    expect(screen.getByText(/version unknown/)).toBeInTheDocument()
  })

  it("renders the build metadata as plain text when there is no pipeline URL", () => {
    w.__RUNTIME_CONFIG__ = {
      VERSION: "1.2.3",
      BUILD_NUMBER: "42",
      GIT_BRANCH: "main",
      GIT_COMMIT: "abc1234",
    }
    render(<VersionValue />)
    expect(screen.getByText(/v1\.2\.3/)).toBeInTheDocument()
    expect(screen.getByText(/main@abc1234/)).toBeInTheDocument()
    expect(screen.queryByRole("link")).not.toBeInTheDocument()
  })

  it("links to the pipeline when the URL survives validation", () => {
    w.__RUNTIME_CONFIG__ = {
      VERSION: "1.2.3",
      BUILD_NUMBER: "42",
      GIT_BRANCH: "main",
      GIT_COMMIT: "abc1234",
      PIPELINE_URL: "https://jenkins.example.com/job/flowharbor-prod/7/",
    }
    render(<VersionValue />)
    expect(screen.getByRole("link", { name: "pipeline" })).toHaveAttribute(
      "href",
      "https://jenkins.example.com/job/flowharbor-prod/7/"
    )
  })

  it("drops a hostile pipeline URL to the plain-text variant", () => {
    w.__RUNTIME_CONFIG__ = {
      VERSION: "1.2.3",
      BUILD_NUMBER: "42",
      GIT_BRANCH: "main",
      GIT_COMMIT: "abc1234",
      PIPELINE_URL: "javascript:alert(1)",
    }
    render(<VersionValue />)
    expect(screen.queryByRole("link")).not.toBeInTheDocument()
  })
})
