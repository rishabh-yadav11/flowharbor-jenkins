#!/bin/sh
set -eu
: "${PORT:=3000}"
export PORT

# Issue #15: the container runs with readonlyRootFilesystem=true. Writable
# paths are provided via task-def mounts: /tmp (scratch) and /app/public
# (empty volume so runtime-config.js can be generated at boot).
# NOTE: /app/public is an EMPTY volume at runtime — baked static assets under
# public/ are shadowed. Keep only generated files here; app static assets are
# served from .next/static (standalone build), not public/.
# EXPORTED, not just assigned: the node program below reads it through
# process.env, and a plain shell variable is invisible to child processes —
# which would make it write to "undefined/runtime-config.js".
export RUNTIME_CONFIG_DIR="${RUNTIME_CONFIG_DIR:-/app/public}"
mkdir -p /tmp "$RUNTIME_CONFIG_DIR"

# Build runtime config using Node's JSON.stringify so every value is properly
# escaped before being embedded into a <script>. Naive shell interpolation
# here is an XSS vector (a hostile GIT_TAG/URL could break out of the string
# and inject arbitrary JavaScript served to every visitor).
node -e '
const fs = require("fs");
function safeUrl(v, fb) {
  fb = fb || "#";
  v = String(v || "").trim().slice(0, 2048);
  if (!v || v === "#") return fb;
  if (/[\u0000-\u0020\u007F]/.test(v)) return fb;
  try {
    const u = new URL(v);
    const p = u.protocol.toLowerCase();
    return (p === "http:" || p === "https:") ? u.toString().slice(0, 2048) : fb;
  } catch (e) { return fb; }
}
function cap(v, n, fb) { v = (typeof v === "string" ? v : fb).slice(0, n); return v || fb; }
function serialize(v) { return JSON.stringify(v).replace(/</g, "\\u003c").replace(/>/g, "\\u003e").replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029"); }
const cfg = {
  ENV: (function (v) { return (v === "dev" || v === "staging" || v === "prod") ? v : "dev"; })(cap(process.env.ENV, 128, "dev")),
  VERSION: cap(process.env.VERSION, 128, "1.0.0"),
  BUILD_NUMBER: cap(process.env.BUILD_NUMBER, 128, "0"),
  GIT_COMMIT: cap(process.env.GIT_COMMIT, 128, "unknown"),
  GIT_BRANCH: cap(process.env.GIT_BRANCH, 128, "unknown"),
  GIT_AUTHOR: String(process.env.GIT_AUTHOR || "unknown").replace(/[\r\n]+/g, " ").slice(0, 256).trim() || "unknown",
  TIMESTAMP: cap(process.env.TIMESTAMP, 128, "unknown"),
  PIPELINE_URL: safeUrl(process.env.PIPELINE_URL, "#"),
};
const js = "window.__RUNTIME_CONFIG__=Object.freeze(" + serialize(cfg) + ");";
// Defence in depth: every value is capped above (128 chars, 2048 for the URL),
// so the generated payload can never reach 8192 bytes. The same limit is
// enforced on the TypeScript side in parseRuntimeConfig.
if (js.length > 8192) { console.error("runtime-config oversize"); process.exit(1); }
fs.writeFileSync(process.env.RUNTIME_CONFIG_DIR + "/runtime-config.js", js);
'

# Test hook: FLOWHARBOR_SKIP_EXEC=1 generates runtime-config.js without starting
# the server (used by app/tests/entrypoint.test.ts).
if [ "${FLOWHARBOR_SKIP_EXEC:-0}" = "1" ]; then exit 0; fi

exec node server.js