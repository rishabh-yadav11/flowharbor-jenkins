import { spawnSync } from "node:child_process"
import { copyFileSync, mkdtempSync } from "node:fs"
import { copyFile, mkdtemp, readFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { describe, expect, it } from "vitest"
const repoRoot = path.resolve(import.meta.dirname, "..")

async function boot(env: Record<string, string>) {
  const dir = await mkdtemp(path.join(tmpdir(), "flowharbor-entrypoint-"))
  const script = path.join(dir, "entrypoint.sh")
  await copyFile(path.join(repoRoot, "entrypoint.sh"), script)

  const publicDir = path.join(dir, "public")
  const result = spawnSync("sh", [script], {
    cwd: dir,
    encoding: "utf8",
    env: {
      PATH: process.env.PATH,
      HOME: dir,
      NODE_ENV: "test",
      RUNTIME_CONFIG_DIR: publicDir,
      FLOWHARBOR_SKIP_EXEC: "1",
      ...env,
    },
  })

  const file = path.join(publicDir, "runtime-config.js")
  const contents = await readFile(file, "utf8")
  return { result, contents }
}

// Runs the entrypoint with RUNTIME_CONFIG_DIR absent from the environment, so
// the script must fall back to /app/public AND pass that path to node through
// the environment. A plain (unexported) shell assignment would leave
// process.env.RUNTIME_CONFIG_DIR undefined and node would try to write
// "undefined/runtime-config.js" instead.
function bootWithDefaultDir() {
  const dir = mkdtempSync(path.join(tmpdir(), "flowharbor-entrypoint-default-"))
  const script = path.join(dir, "entrypoint.sh")
  copyFileSync(path.join(repoRoot, "entrypoint.sh"), script)
  return spawnSync("sh", [script], {
    cwd: dir,
    encoding: "utf8",
    env: {
      PATH: process.env.PATH,
      HOME: dir,
      NODE_ENV: "test",
      FLOWHARBOR_SKIP_EXEC: "1",
    },
  })
}

describe("entrypoint.sh runtime config generation", () => {
  it("exits 0 and writes the generated file into RUNTIME_CONFIG_DIR", async () => {
    const { result, contents } = await boot({ VERSION: "1.2.3" })
    expect(result.status).toBe(0)
    expect(contents).toContain('"VERSION":"1.2.3"')
  })

  it("collapses a newline in GIT_AUTHOR onto a single line", async () => {
    const { contents } = await boot({ GIT_AUTHOR: "evil\nInjected: x" })
    expect(contents).not.toContain("\n")
    expect(contents).toContain('"GIT_AUTHOR":"evil Injected: x"')
  })

  it('neutralises a javascript: PIPELINE_URL to "#"', async () => {
    const { contents } = await boot({ PIPELINE_URL: "javascript:alert(1)" })
    expect(contents).toContain('"PIPELINE_URL":"#"')
  })

  it('falls back to env "dev" for an unknown ENV', async () => {
    const { contents } = await boot({ ENV: "bogus" })
    expect(contents).toContain('"ENV":"dev"')
  })

  it("escapes a </script> GIT_AUTHOR so the payload cannot break out", async () => {
    const { contents } = await boot({ GIT_AUTHOR: "</script><script>alert(1)</script>" })
    expect(contents).not.toContain("<")
    expect(contents).toContain("\\u003c/script\\u003e")
  })

  it("falls back to the container's /app/public and exports it to node", () => {
    const result = bootWithDefaultDir()
    const output = `${result.stdout}${result.stderr}`
    // Either /app/public is writable (the file is written) or it is not (mkdir
    // fails). What must never happen is a write under "undefined/".
    expect(output).not.toContain("undefined/runtime-config.js")
    if (result.status !== 0) {
      // mkdir reports the first component it could not create (/app), which is
      // still proof the default path was used instead of "undefined".
      expect(output).toContain("/app")
    }
  })
})
