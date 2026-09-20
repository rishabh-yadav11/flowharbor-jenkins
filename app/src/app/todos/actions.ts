"use server"

import { revalidatePath } from "next/cache"
import { getRepository } from "@/lib/todos/repository"
import { parseTitle, parseTodoId } from "@/lib/todos/validate"

export type ActionResult = { ok: true } | { ok: false; error: string }

export async function createTodo(formData: FormData): Promise<ActionResult> {
  const parsed = parseTitle(formData.get("title"))
  if (!parsed.ok) return { ok: false, error: parsed.error }
  try {
    await getRepository().create(parsed.title)
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "could not add todo" }
  }
  revalidatePath("/")
  return { ok: true }
}

export async function toggleTodo(id: string, done: boolean): Promise<ActionResult> {
  const parsed = parseTodoId(id)
  if (!parsed.ok) return { ok: false, error: parsed.error }
  try {
    const todo = await getRepository().setDone(parsed.id, done)
    if (!todo) return { ok: false, error: "todo not found" }
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "could not update todo" }
  }
  revalidatePath("/")
  return { ok: true }
}

export async function deleteTodo(id: string): Promise<ActionResult> {
  const parsed = parseTodoId(id)
  if (!parsed.ok) return { ok: false, error: parsed.error }
  try {
    if (!(await getRepository().remove(parsed.id))) {
      return { ok: false, error: "todo not found" }
    }
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "could not delete todo" }
  }
  revalidatePath("/")
  return { ok: true }
}
