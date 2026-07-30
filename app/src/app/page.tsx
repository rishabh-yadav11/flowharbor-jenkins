import { TodoApp } from "@/components/todo-app"

export default function Home() {
  return (
    <main className="min-h-dvh flex items-center justify-center bg-gradient-to-br from-background to-muted p-4">
      <TodoApp />
    </main>
  )
}
