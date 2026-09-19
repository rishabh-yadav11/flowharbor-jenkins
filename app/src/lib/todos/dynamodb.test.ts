import { DeleteCommand, PutCommand, ScanCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb"
import type { DynamoDBDocumentClient } from "@aws-sdk/lib-dynamodb"
import { describe, expect, it, vi } from "vitest"
import { createDynamoRepository } from "@/lib/todos/dynamodb"

type Command = { input: Record<string, unknown> }

function stub(responses: unknown[]) {
  const sent: Command[] = []
  const doc = {
    send: vi.fn(async (cmd: Command) => {
      sent.push(cmd)
      const next = responses.shift()
      if (next instanceof Error) throw next
      return next ?? {}
    }),
  } as unknown as DynamoDBDocumentClient
  return { doc, sent }
}

const item = (id: string, createdAt: string) => ({
  pk: `TODO#${id}`,
  title: `todo ${id}`,
  done: false,
  createdAt,
  updatedAt: createdAt,
})

describe("createDynamoRepository", () => {
  it("creates with a conditional put keyed on the todo pk", async () => {
    const { doc, sent } = stub([{}])
    const todo = await createDynamoRepository(doc, "todos").create("ship it")

    expect(sent[0]).toBeInstanceOf(PutCommand)
    expect(sent[0].input).toMatchObject({
      TableName: "todos",
      ConditionExpression: "attribute_not_exists(pk)",
    })
    const put = sent[0].input.Item as { pk: string; title: string; done: boolean }
    expect(put.pk).toBe(`TODO#${todo.id}`)
    expect(put.title).toBe("ship it")
    expect(put.done).toBe(false)
  })

  it("maps a conditional check failure to a readable error", async () => {
    const failure = Object.assign(new Error("exists"), {
      name: "ConditionalCheckFailedException",
    })
    const { doc } = stub([failure])
    await expect(createDynamoRepository(doc, "todos").create("dupe")).rejects.toThrow(
      "todo already exists"
    )
  })

  it("rethrows unexpected failures untouched", async () => {
    const { doc } = stub([new Error("ResourceNotFound")])
    await expect(createDynamoRepository(doc, "todos").create("boom")).rejects.toThrow(
      "ResourceNotFound"
    )
  })

  it("pages a list until LastEvaluatedKey is gone", async () => {
    const { doc, sent } = stub([
      { Items: [item("a", "2026-01-02T00:00:00.000Z")], LastEvaluatedKey: { pk: "TODO#a" } },
      { Items: [item("b", "2026-01-01T00:00:00.000Z")] },
    ])
    const todos = await createDynamoRepository(doc, "todos").list()

    expect(sent).toHaveLength(2)
    expect(sent[0]).toBeInstanceOf(ScanCommand)
    expect(sent[1].input.ExclusiveStartKey).toEqual({ pk: "TODO#a" })
    expect(todos.map((t) => t.id)).toEqual(["a", "b"])
  })

  it("strips the pk prefix when mapping items", async () => {
    const { doc } = stub([{ Items: [item("abc", "2026-01-01T00:00:00.000Z")] }])
    const [todo] = await createDynamoRepository(doc, "todos").list()
    expect(todo.id).toBe("abc")
    expect(todo.title).toBe("todo abc")
  })

  it("updates done with an explicit attribute-name mapping", async () => {
    const { doc, sent } = stub([{ Attributes: item("a", "2026-01-01T00:00:00.000Z") }])
    const todo = await createDynamoRepository(doc, "todos").setDone("a", true)

    expect(sent[0]).toBeInstanceOf(UpdateCommand)
    expect(sent[0].input).toMatchObject({
      Key: { pk: "TODO#a" },
      ReturnValues: "ALL_NEW",
      ExpressionAttributeValues: { ":done": true },
    })
    expect(todo?.id).toBe("a")
  })

  it("returns null when the update affects no row", async () => {
    const { doc } = stub([{}])
    expect(await createDynamoRepository(doc, "todos").setDone("a", true)).toBeNull()
  })

  it("reports whether a delete removed a row", async () => {
    const found = stub([{ Attributes: item("a", "2026-01-01T00:00:00.000Z") }])
    expect(await createDynamoRepository(found.doc, "todos").remove("a")).toBe(true)
    expect(found.sent[0]).toBeInstanceOf(DeleteCommand)

    const missing = stub([{}])
    expect(await createDynamoRepository(missing.doc, "todos").remove("a")).toBe(false)
  })
})
