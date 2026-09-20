import { buildHealthPayload } from "@/lib/health"
import { pingDatabase } from "@/lib/todos/repository"

export const dynamic = "force-dynamic"

// A health check that hangs is worse than one that fails: the ALB target group
// and the pipeline's post-deploy smoke both need a definitive answer.
const PING_TIMEOUT_MS = 2000

export async function GET() {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), PING_TIMEOUT_MS)
  let database: { ok: boolean; detail: string }
  try {
    database = await pingDatabase(controller.signal)
  } catch (e) {
    database = { ok: false, detail: e instanceof Error ? e.message : "health probe failed" }
  } finally {
    clearTimeout(timer)
  }

  const payload = buildHealthPayload(
    {
      ENV: process.env.ENV,
      VERSION: process.env.VERSION,
      BUILD_NUMBER: process.env.BUILD_NUMBER,
      GIT_COMMIT: process.env.GIT_COMMIT,
    },
    database
  )

  return Response.json(payload, {
    status: payload.status === "ok" ? 200 : 503,
    headers: { "Cache-Control": "no-store" },
  })
}
