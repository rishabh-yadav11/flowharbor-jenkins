const MAX_TITLE_LEN = 120
const CONTROL_CHARS = /[\u0000-\u001f\u007f]/
const TODO_ID = /^[A-Za-z0-9-]{1,64}$/

export type TitleResult = { ok: true; title: string } | { ok: false; error: string }
export type IdResult = { ok: true; id: string } | { ok: false; error: string }

export function parseTitle(raw: unknown): TitleResult {
  if (typeof raw !== "string") return { ok: false, error: "title is required" }
  const title = raw.trim()
  if (!title) return { ok: false, error: "title is required" }
  if (title.length > MAX_TITLE_LEN) {
    return { ok: false, error: `title must be ${MAX_TITLE_LEN} characters or fewer` }
  }
  if (CONTROL_CHARS.test(title)) {
    return { ok: false, error: "title contains control characters" }
  }
  return { ok: true, title }
}

export function parseTodoId(raw: unknown): IdResult {
  if (typeof raw !== "string" || !TODO_ID.test(raw)) {
    return { ok: false, error: "invalid todo id" }
  }
  return { ok: true, id: raw }
}
