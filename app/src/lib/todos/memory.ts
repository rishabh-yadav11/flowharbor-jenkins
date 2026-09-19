import { randomUUID } from "node:crypto"
import type { Todo } from "./types"
import type { TodoRepository } from "./repository"

export const SEED_TODOS: Todo[] = [
  {
    id: "seed-1",
    title: "Wire the ECS task definition to a digest-pinned image",
    done: false,
    createdAt: "2026-01-05T09:00:00.000Z",
    updatedAt: "2026-01-05T09:00:00.000Z",
  },
  {
    id: "seed-2",
    title: "Confirm the ECR scan gate refuses an unscanned digest",
    done: true,
    createdAt: "2026-01-05T09:01:00.000Z",
    updatedAt: "2026-01-05T09:05:00.000Z",
  },
  {
    id: "seed-3",
    title: "Roll the previous task definition back by hand",
    done: false,
    createdAt: "2026-01-05T09:02:00.000Z",
    updatedAt: "2026-01-05T09:02:00.000Z",
  },
]

const copy = (todo: Todo): Todo => ({ ...todo })

// Newest first, ties broken by id ascending, so a reload always renders in the
// same order regardless of insertion sequence.
function byNewestFirst(a: Todo, b: Todo): number {
  if (a.createdAt === b.createdAt) return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
  return a.createdAt < b.createdAt ? 1 : -1
}

export function createMemoryRepository(seed: Todo[] = SEED_TODOS): TodoRepository {
  const items = new Map<string, Todo>(seed.map((t) => [t.id, copy(t)]))

  return {
    async list(): Promise<Todo[]> {
      return Array.from(items.values()).map(copy).sort(byNewestFirst)
    },

    async create(title: string): Promise<Todo> {
      const now = new Date().toISOString()
      const todo: Todo = {
        id: randomUUID(),
        title,
        done: false,
        createdAt: now,
        updatedAt: now,
      }
      items.set(todo.id, todo)
      return copy(todo)
    },

    async setDone(id: string, done: boolean): Promise<Todo | null> {
      const existing = items.get(id)
      if (!existing) return null
      const updated: Todo = { ...existing, done, updatedAt: new Date().toISOString() }
      items.set(id, updated)
      return copy(updated)
    },

    async remove(id: string): Promise<boolean> {
      return items.delete(id)
    },
  }
}
