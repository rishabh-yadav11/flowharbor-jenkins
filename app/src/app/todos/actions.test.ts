import { beforeEach, describe, expect, it, vi, type Mock } from "vitest"
// vi.mock is hoisted above the imports by vitest's transform, so these
// bindings are the mocked module's exports.
import { createTodo, deleteTodo, toggleTodo } from "@/app/todos/actions"
import type { TodoRepository } from "@/lib/todos/repository"
import type { Todo } from "@/lib/todos/types"

// vi.hoisted: both factories below are hoisted above the imports, so the stub
// repository and the revalidatePath spy must exist before the module body runs.
const { repository, revalidatePath } = vi.hoisted(() => {
  const makeTodo = (title: string): Todo => ({
    id: "seed-1",
    title,
    done: false,
    createdAt: "2026-01-05T09:00:00.000Z",
    updatedAt: "2026-01-05T09:00:00.000Z",
  })
  return {
    revalidatePath: vi.fn(),
    repository: {
      list: vi.fn(async () => [] as Todo[]),
      create: vi.fn(async (title: string) => makeTodo(title)),
      setDone: vi.fn(async () => null as Todo | null),
      remove: vi.fn(async () => true),
    },
  }
}) as { repository: TodoRepository; revalidatePath: Mock }

vi.mock("next/cache", () => ({ revalidatePath }))
vi.mock("@/lib/todos/repository", () => ({ getRepository: () => repository }))

beforeEach(() => {
  revalidatePath.mockClear()
  vi.mocked(repository.create).mockClear()
  vi.mocked(repository.setDone).mockClear()
  vi.mocked(repository.remove).mockClear()
})

describe("createTodo", () => {
  it("rejects an empty title without touching the repository", async () => {
    const form = new FormData()
    form.set("title", "   ")
    expect(await createTodo(form)).toEqual({ ok: false, error: "title is required" })
    expect(repository.create).not.toHaveBeenCalled()
    expect(revalidatePath).not.toHaveBeenCalled()
  })

  it("rejects a missing title field", async () => {
    expect(await createTodo(new FormData())).toEqual({
      ok: false,
      error: "title is required",
    })
  })

  it("rejects an over-long title", async () => {
    const form = new FormData()
    form.set("title", "x".repeat(121))
    expect(await createTodo(form)).toEqual({
      ok: false,
      error: "title must be 120 characters or fewer",
    })
  })

  it("rejects control characters", async () => {
    const form = new FormData()
    form.set("title", "bad\u0000title")
    expect(await createTodo(form)).toEqual({
      ok: false,
      error: "title contains control characters",
    })
  })

  it("trims and stores a valid title, then revalidates the page", async () => {
    const form = new FormData()
    form.set("title", "  wire the ACL  ")
    expect(await createTodo(form)).toEqual({ ok: true })
    expect(repository.create).toHaveBeenCalledWith("wire the ACL")
    expect(revalidatePath).toHaveBeenCalledWith("/")
  })

  it("returns the repository error instead of throwing", async () => {
    vi.mocked(repository.create).mockRejectedValueOnce(new Error("ProvisionedThroughputExceeded"))
    const form = new FormData()
    form.set("title", "spike")
    expect(await createTodo(form)).toEqual({
      ok: false,
      error: "ProvisionedThroughputExceeded",
    })
    expect(revalidatePath).not.toHaveBeenCalled()
  })
})

describe("toggleTodo", () => {
  it("rejects a malformed id", async () => {
    expect(await toggleTodo("../etc/passwd", true)).toEqual({
      ok: false,
      error: "invalid todo id",
    })
    expect(repository.setDone).not.toHaveBeenCalled()
  })

  it("reports a missing todo", async () => {
    expect(await toggleTodo("missing-id", true)).toEqual({ ok: false, error: "todo not found" })
  })

  it("persists the change and revalidates", async () => {
    vi.mocked(repository.setDone).mockResolvedValueOnce({
      id: "seed-1",
      title: "done",
      done: true,
      createdAt: "2026-01-05T09:00:00.000Z",
      updatedAt: "2026-01-05T09:00:00.000Z",
    })
    expect(await toggleTodo("seed-1", true)).toEqual({ ok: true })
    expect(repository.setDone).toHaveBeenCalledWith("seed-1", true)
    expect(revalidatePath).toHaveBeenCalledWith("/")
  })
})

describe("deleteTodo", () => {
  it("rejects a malformed id", async () => {
    expect(await deleteTodo("no spaces allowed")).toEqual({
      ok: false,
      error: "invalid todo id",
    })
  })

  it("reports a missing todo", async () => {
    vi.mocked(repository.remove).mockResolvedValueOnce(false)
    expect(await deleteTodo("seed-1")).toEqual({ ok: false, error: "todo not found" })
  })

  it("removes the todo and revalidates", async () => {
    expect(await deleteTodo("seed-1")).toEqual({ ok: true })
    expect(repository.remove).toHaveBeenCalledWith("seed-1")
    expect(revalidatePath).toHaveBeenCalledWith("/")
  })
})
