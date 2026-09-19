import { DescribeTableCommand } from "@aws-sdk/client-dynamodb"
import { createDynamoRepository, defaultDocumentClient } from "./dynamodb"
import { createMemoryRepository } from "./memory"
import type { Todo } from "./types"

export interface TodoRepository {
  list(): Promise<Todo[]>
  create(title: string): Promise<Todo>
  setDone(id: string, done: boolean): Promise<Todo | null>
  remove(id: string): Promise<boolean>
}

export type DatabaseStatus = { ok: boolean; detail: string }

// Process-level singleton: the page render and every server action must see the
// same store, otherwise an in-memory write would be discarded by the next call.
let singleton: TodoRepository | null = null

// ECS sets DATA_BACKEND=dynamodb; every other environment (npm run dev, the
// container image without infra, tests) uses the in-memory store, so the app
// runs with zero AWS access.
export function getRepository(): TodoRepository {
  if (singleton) return singleton
  if (process.env.DATA_BACKEND === "dynamodb") {
    const table = process.env.TODO_TABLE ?? ""
    if (!table) throw new Error("DATA_BACKEND=dynamodb requires TODO_TABLE")
    singleton = createDynamoRepository(defaultDocumentClient(), table)
  } else {
    singleton = createMemoryRepository()
  }
  return singleton
}

export async function pingDatabase(signal?: AbortSignal): Promise<DatabaseStatus> {
  if (process.env.DATA_BACKEND !== "dynamodb") {
    return { ok: true, detail: "in-memory" }
  }
  const table = process.env.TODO_TABLE ?? ""
  if (!table) return { ok: false, detail: "TODO_TABLE is not set" }
  try {
    const res = await defaultDocumentClient().send(
      new DescribeTableCommand({ TableName: table }),
      signal ? { abortSignal: signal } : undefined
    )
    const status = res.Table?.TableStatus
    return status === "ACTIVE"
      ? { ok: true, detail: `dynamodb:${table}` }
      : { ok: false, detail: `dynamodb:${table} is ${status ?? "UNKNOWN"}` }
  } catch (e) {
    return { ok: false, detail: e instanceof Error ? e.message : "dynamodb unreachable" }
  }
}
