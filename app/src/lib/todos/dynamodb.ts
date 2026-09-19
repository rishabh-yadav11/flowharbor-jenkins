import { randomUUID } from "node:crypto"
import { DynamoDBClient } from "@aws-sdk/client-dynamodb"
import {
  DeleteCommand,
  DynamoDBDocumentClient,
  PutCommand,
  ScanCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb"
import type { Todo } from "./types"
import type { TodoRepository } from "./repository"

interface TodoItem {
  pk: string
  title: string
  done: boolean
  createdAt: string
  updatedAt: string
}

const toTodo = (item: TodoItem): Todo => ({
  id: item.pk.replace(/^TODO#/, ""),
  title: item.title,
  done: item.done,
  createdAt: item.createdAt,
  updatedAt: item.updatedAt,
})

export function createDynamoRepository(
  doc: DynamoDBDocumentClient,
  table: string
): TodoRepository {
  return {
    async list(): Promise<Todo[]> {
      const items: TodoItem[] = []
      let startKey: Record<string, unknown> | undefined
      do {
        const res = await doc.send(
          new ScanCommand({ TableName: table, ExclusiveStartKey: startKey })
        )
        items.push(...((res.Items ?? []) as TodoItem[]))
        startKey = res.LastEvaluatedKey as Record<string, unknown> | undefined
      } while (startKey)
      return items
        .map(toTodo)
        .sort((a, b) =>
          a.createdAt === b.createdAt
            ? a.id < b.id
              ? -1
              : 1
            : a.createdAt < b.createdAt
              ? 1
              : -1
        )
    },

    async create(title: string): Promise<Todo> {
      const now = new Date().toISOString()
      const item: TodoItem = {
        pk: `TODO#${randomUUID()}`,
        title,
        done: false,
        createdAt: now,
        updatedAt: now,
      }
      try {
        await doc.send(
          new PutCommand({
            TableName: table,
            Item: item,
            ConditionExpression: "attribute_not_exists(pk)",
          })
        )
      } catch (e) {
        if (e instanceof Error && e.name === "ConditionalCheckFailedException") {
          throw new Error("todo already exists")
        }
        throw e
      }
      return toTodo(item)
    },

    async setDone(id: string, done: boolean): Promise<Todo | null> {
      const res = await doc.send(
        new UpdateCommand({
          TableName: table,
          Key: { pk: `TODO#${id}` },
          UpdateExpression: "SET #d = :done, #u = :now",
          ExpressionAttributeNames: { "#d": "done", "#u": "updatedAt" },
          ExpressionAttributeValues: {
            ":done": done,
            ":now": new Date().toISOString(),
          },
          ReturnValues: "ALL_NEW",
        })
      )
      return res.Attributes ? toTodo(res.Attributes as TodoItem) : null
    },

    async remove(id: string): Promise<boolean> {
      const res = await doc.send(
        new DeleteCommand({
          TableName: table,
          Key: { pk: `TODO#${id}` },
          ReturnValues: "ALL_OLD",
        })
      )
      return res.Attributes != null
    },
  }
}

// Created lazily so a memory-backed local run never constructs an AWS client
// (which would try to resolve region/credentials on first use).
let cached: DynamoDBDocumentClient | null = null

export function defaultDocumentClient(): DynamoDBDocumentClient {
  if (!cached) {
    cached = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
      marshallOptions: { removeUndefinedValues: true },
    })
  }
  return cached
}
