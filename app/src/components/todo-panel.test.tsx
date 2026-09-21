/** @vitest-environment jsdom */
import { cleanup, render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
// vi.hoisted: the factory below is hoisted above the imports, so the mock
// functions must exist before this module's body runs.
const { createTodo, toggleTodo, deleteTodo } = vi.hoisted(() => ({
  createTodo: vi.fn(),
  toggleTodo: vi.fn(),
  deleteTodo: vi.fn(),
}))
vi.mock("@/app/todos/actions", () => ({ createTodo, toggleTodo, deleteTodo }))

import { TodoPanel } from "@/components/todo-panel"
import type { Todo } from "@/lib/todos/types"

const todos: Todo[] = [
  {
    id: "seed-1",
    title: "Wire the ECS task definition",
    done: false,
    createdAt: "2026-01-05T09:00:00.000Z",
    updatedAt: "2026-01-05T09:00:00.000Z",
  },
  {
    id: "seed-2",
    title: "Roll back the previous revision",
    done: true,
    createdAt: "2026-01-05T09:01:00.000Z",
    updatedAt: "2026-01-05T09:02:00.000Z",
  },
]

beforeEach(() => {
  vi.clearAllMocks()
  createTodo.mockResolvedValue({ ok: true })
  toggleTodo.mockResolvedValue({ ok: true })
  deleteTodo.mockResolvedValue({ ok: true })
})

afterEach(cleanup)

describe("TodoPanel", () => {
  it("renders one row per todo with its done state", () => {
    render(<TodoPanel initialTodos={todos} />)
    expect(screen.getByText("Wire the ECS task definition")).toBeInTheDocument()
    expect(screen.getByText("Roll back the previous revision")).toBeInTheDocument()
    expect(document.querySelectorAll("[data-done]")).toHaveLength(2)
    expect(document.querySelector('[data-done="true"]')).toHaveTextContent(
      "Roll back the previous revision"
    )
  })

  it("toggles a todo and shows the optimistic done state", async () => {
    const user = userEvent.setup()
    render(<TodoPanel initialTodos={todos} />)

    await user.click(screen.getByRole("checkbox", { name: "Toggle Wire the ECS task definition" }))

    expect(toggleTodo).toHaveBeenCalledWith("seed-1", true)
    await waitFor(() =>
      expect(document.querySelector("li")?.getAttribute("data-done")).toBe("true")
    )
  })

  it("surfaces a failed toggle in an alert and reverts the row", async () => {
    const user = userEvent.setup()
    toggleTodo.mockResolvedValueOnce({ ok: false, error: "boom" })
    render(<TodoPanel initialTodos={todos} />)

    await user.click(screen.getByRole("checkbox", { name: "Toggle Wire the ECS task definition" }))

    await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent("boom"))
    expect(document.querySelector("li")?.getAttribute("data-done")).toBe("false")
  })

  it("deletes a todo through the row action", async () => {
    const user = userEvent.setup()
    render(<TodoPanel initialTodos={todos} />)

    await user.click(screen.getByRole("button", { name: "Delete Roll back the previous revision" }))

    expect(deleteTodo).toHaveBeenCalledWith("seed-2")
    await waitFor(() => expect(document.querySelectorAll("[data-done]")).toHaveLength(1))
  })

  it("renders an empty state when there is nothing to do", () => {
    render(<TodoPanel initialTodos={[]} />)
    expect(screen.getByText("Nothing left to deploy.")).toBeInTheDocument()
  })
})
