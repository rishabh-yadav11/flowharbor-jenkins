"use client"

import { useActionState, useOptimistic, useState, useTransition } from "react"
import { createTodo, deleteTodo, toggleTodo } from "@/app/todos/actions"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardTitle } from "@/components/ui/card"
import { Checkbox } from "@/components/ui/checkbox"
import { Input } from "@/components/ui/input"
import type { Todo } from "@/lib/todos/types"
import { cn } from "@/lib/utils"

type Mutation =
  | { type: "toggle"; id: string; done: boolean }
  | { type: "delete"; id: string }

type ActionResult = { ok: true } | { ok: false; error: string }

const applyMutation = (todos: Todo[], mutation: Mutation): Todo[] =>
  mutation.type === "delete"
    ? todos.filter((t) => t.id !== mutation.id)
    : todos.map((t) => (t.id === mutation.id ? { ...t, done: mutation.done } : t))

const initialFormState: { error: string | null } = { error: null }

export function TodoPanel({ initialTodos }: { initialTodos: Todo[] }) {
  const [todos, setTodos] = useState(initialTodos)
  const [error, setError] = useState<string | null>(null)
  const [isPending, startTransition] = useTransition()
  const [optimisticTodos, applyOptimistic] = useOptimistic(todos, applyMutation)

  // The server revalidates `/` after every successful action, so new props are
  // the source of truth. React's documented alternative to a syncing effect:
  // adjust the state during render when the prop identity changes.
  const [syncedFrom, setSyncedFrom] = useState(initialTodos)
  if (syncedFrom !== initialTodos) {
    setSyncedFrom(initialTodos)
    setTodos(initialTodos)
  }

  const [formState, formAction, isSubmitting] = useActionState(
    async (_prev: { error: string | null }, formData: FormData) => {
      const result = await createTodo(formData)
      return { error: result.ok ? null : result.error }
    },
    initialFormState
  )

  function run(mutation: Mutation, call: () => Promise<ActionResult>) {
    setError(null)
    startTransition(async () => {
      applyOptimistic(mutation)
      const result = await call()
      if (result.ok) {
        setTodos((prev) => applyMutation(prev, mutation))
      } else {
        setError(result.error)
      }
    })
  }

  return (
    <Card className="w-full max-w-xl border-white/10 bg-white/5 text-white backdrop-blur-md">
      <CardContent>
        <CardTitle className="text-white/80">Deployment todos</CardTitle>

        <form action={formAction} className="mt-4 flex gap-2">
          <Input
            name="title"
            maxLength={120}
            placeholder="Add a todo…"
            aria-label="Todo title"
            className="border-white/10 bg-white/5 text-white placeholder:text-white/30"
          />
          <Button type="submit" disabled={isSubmitting}>
            Add
          </Button>
        </form>

        {formState.error && (
          <p role="alert" className="mt-2 text-sm text-red-300">
            {formState.error}
          </p>
        )}
        {error && (
          <p role="alert" className="mt-2 text-sm text-red-300">
            {error}
          </p>
        )}

        <ul className="mt-4 space-y-2">
          {optimisticTodos.map((todo) => (
            <li
              key={todo.id}
              data-done={todo.done}
              className={cn(
                "flex items-center gap-3 rounded-md px-2 py-1 text-sm",
                todo.done && "text-white/40 line-through"
              )}
            >
              <Checkbox
                checked={todo.done}
                aria-label={`Toggle ${todo.title}`}
                onCheckedChange={(checked) => {
                  const done = checked === true
                  run({ type: "toggle", id: todo.id, done }, () => toggleTodo(todo.id, done))
                }}
              />
              <span className="flex-1">{todo.title}</span>
              <Button
                type="button"
                variant="ghost"
                size="icon"
                aria-label={`Delete ${todo.title}`}
                disabled={isPending}
                onClick={() => run({ type: "delete", id: todo.id }, () => deleteTodo(todo.id))}
              >
                ×
              </Button>
            </li>
          ))}
        </ul>

        {optimisticTodos.length === 0 && (
          <p className="mt-4 text-sm text-white/40">Nothing left to deploy.</p>
        )}
      </CardContent>
    </Card>
  )
}
