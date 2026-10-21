import { fileURLToPath } from "node:url"
import react from "@vitejs/plugin-react"
import { defineConfig } from "vitest/config"

// Mirrors the `@/*` -> `./src/*` alias in tsconfig.json.
const srcDir = fileURLToPath(new URL("./src", import.meta.url))

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { "@": srcDir },
  },
  test: {
    environment: "node",
    setupFiles: ["./vitest.setup.ts"],
    include: ["src/**/*.test.{ts,tsx}", "tests/**/*.test.ts"],
    coverage: {
      provider: "v8",
      reporter: ["text", "lcov", "json-summary"],
      include: ["src/**/*.{ts,tsx}"],
      // Next.js plumbing and presentational primitives: rendered by the runtime
      // smoke (Verification item 4) or by no logic at all, so unit-test
      // coverage of them would measure nothing.
      exclude: [
        "src/**/*.d.ts",
        "src/app/layout.tsx",
        "src/app/globals.css",
        "src/components/ui/**",
        "src/components/particle-field.tsx",
      ],
      thresholds: {
        lines: 70,
        functions: 70,
        statements: 70,
        branches: 60,
        // Branch gate calibrated to @vitest/coverage-v8@5, which attributes
        // defensive/error branches (DynamoDB status/optional-chain paths,
        // comparator tied-id edges) that the 3.x counter ignored. Measured
        // 81.45% (101/124) with identical code and tests.
        "src/lib/**": {
          lines: 90,
          functions: 90,
          statements: 90,
          branches: 80,
        },
      },
    },
  },
})
