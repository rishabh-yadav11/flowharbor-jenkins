import { defineConfig, globalIgnores } from "eslint/config"
import js from "@eslint/js"
import tseslint from "typescript-eslint"
import reactHooks from "eslint-plugin-react-hooks"
import globals from "globals"

export default defineConfig([
  js.configs.recommended,
  ...tseslint.configs.recommended,
  [reactHooks.configs.flat["recommended-latest"]],
  {
    rules: {
      "no-console": ["warn", { allow: ["warn", "error"] }],
    },
  },
  {
    files: ["next.config.js", "postcss.config.js"],
    languageOptions: { globals: globals.node },
  },
  {
    files: ["public/runtime-config.js"],
    languageOptions: { globals: globals.browser },
  },
  {
    files: ["src/lib/todos/validate.ts", "src/lib/runtime-config.ts"],
    rules: { "no-control-regex": "off" },
  },
  globalIgnores([".next/**", "node_modules/**", "coverage/**", "next-env.d.ts"]),
])
