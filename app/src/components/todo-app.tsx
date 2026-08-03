"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Checkbox } from "@/components/ui/checkbox"
import { Plus, Trash2 } from "lucide-react"

interface Todo {
  id: string
  text: string
  done: boolean
}

function useRuntimeConfig() {
  if (typeof window === "undefined") return null
  return (window as unknown as { __RUNTIME_CONFIG__?: Record<string, string> }).__RUNTIME_CONFIG__ ?? null
}

export function TodoApp() {
  const [todos, setTodos] = useState<Todo[]>([])
  const [input, setInput] = useState("")
  const config = useRuntimeConfig()

  function addTodo() {
    const text = input.trim()
    if (!text) return
    setTodos((prev) => [...prev, { id: crypto.randomUUID(), text, done: false }])
    setInput("")
  }

  function toggleTodo(id: string) {
    setTodos((prev) => prev.map((t) => (t.id === id ? { ...t, done: !t.done } : t)))
  }

  function deleteTodo(id: string) {
    setTodos((prev) => prev.filter((t) => t.id !== id))
  }

  const envBadge = config
    ? { dev: "bg-rose-600", staging: "bg-amber-500", prod: "bg-emerald-500" }[config.ENV] ?? "bg-slate-500"
    : "bg-slate-500"

  return (
    <Card className="w-full max-w-lg">
      <CardHeader>
        <div className="flex items-center justify-between">
          <CardTitle>A Todo List</CardTitle>
          {config && (
            <span className={`px-2.5 py-0.5 rounded-full text-xs font-semibold text-white ${envBadge}`}>
              {config.ENV}
            </span>
          )}
        </div>
        {config && (
          <p className="text-xs text-muted-foreground">
            v{config.VERSION} · build #{config.BUILD_NUMBER} · {config.GIT_BRANCH}@{config.GIT_COMMIT}
          </p>
        )}
      </CardHeader>
      <CardContent>
        <div className="flex gap-2 mb-6">
          <Input
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && addTodo()}
            placeholder="Add a todo..."
          />
          <Button onClick={addTodo} size="icon">
            <Plus className="h-4 w-4" />
          </Button>
        </div>

        {todos.length === 0 ? (
          <p className="text-sm text-muted-foreground text-center py-8">Nothing yet. Add a todo above!</p>
        ) : (
          <ul className="space-y-2">
            {todos.map((todo) => (
              <li key={todo.id} className="flex items-center gap-3 py-1.5 group">
                <Checkbox checked={todo.done} onCheckedChange={() => toggleTodo(todo.id)} />
                <span className={`flex-1 text-sm ${todo.done ? "line-through text-muted-foreground" : ""}`}>
                  {todo.text}
                </span>
                <Button
                  variant="ghost"
                  size="icon"
                  className="opacity-0 group-hover:opacity-100 h-8 w-8"
                  onClick={() => deleteTodo(todo.id)}
                >
                  <Trash2 className="h-3.5 w-3.5" />
                </Button>
              </li>
            ))}
          </ul>
        )}

        {config && (
          <div className="mt-6 pt-4 border-t text-xs text-muted-foreground text-center space-y-0.5">
            <p>Deployed by {config.GIT_AUTHOR}</p>
            <p>{config.TIMESTAMP}</p>
            <a href={config.PIPELINE_URL} target="_blank" rel="noopener noreferrer" className="underline hover:text-foreground">
              View Pipeline
            </a>
          </div>
        )}
      </CardContent>
    </Card>
  )
}
