import { describe, expect, it } from "vitest"
import { createMemoryRepository, SEED_TODOS } from "@/lib/todos/memory"

describe("createMemoryRepository", () => {
  it("lists the three seeds newest first", async () => {
    const repo = createMemoryRepository()
    const todos = await repo.list()
    expect(todos).toHaveLength(3)
    expect(todos.map((t) => t.id)).toEqual(["seed-3", "seed-2", "seed-1"])
    expect(todos[1].done).toBe(true)
  })

  it("returns deep copies, so a caller cannot mutate the store", async () => {
    const repo = createMemoryRepository()
    const first = await repo.list()
    first[0].title = "mutated"
    const second = await repo.list()
    expect(second[0].title).toBe(SEED_TODOS[2].title)
  })

  it("creates a todo with a uuid and identical timestamps", async () => {
    const repo = createMemoryRepository([])
    const todo = await repo.create("wire the WAF ACL")
    expect(todo.id).toMatch(/^[0-9a-f-]{36}$/)
    expect(todo.done).toBe(false)
    expect(todo.createdAt).toBe(todo.updatedAt)
    expect(await repo.list()).toHaveLength(1)
  })

  it("toggles done and returns the updated row", async () => {
    const repo = createMemoryRepository()
    const updated = await repo.setDone("seed-1", true)
    expect(updated?.done).toBe(true)
    expect(updated?.id).toBe("seed-1")
  })

  it("returns null when toggling an unknown id", async () => {
    const repo = createMemoryRepository()
    expect(await repo.setDone("nope", true)).toBeNull()
  })

  it("removes a todo and reports false for an unknown id", async () => {
    const repo = createMemoryRepository()
    expect(await repo.remove("seed-1")).toBe(true)
    expect(await repo.remove("seed-1")).toBe(false)
    expect(await repo.list()).toHaveLength(2)
  })

  it("breaks createdAt ties by ascending id", async () => {
    const same = "2026-01-05T09:00:00.000Z"
    const repo = createMemoryRepository([
      { id: "b", title: "b", done: false, createdAt: same, updatedAt: same },
      { id: "a", title: "a", done: false, createdAt: same, updatedAt: same },
    ])
    expect((await repo.list()).map((t) => t.id)).toEqual(["a", "b"])
  })
})
