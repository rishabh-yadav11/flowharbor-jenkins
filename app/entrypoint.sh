#!/bin/sh
set -e

# Issue #15: the container runs with readonlyRootFilesystem=true. Writable
# paths are provided via task-def mounts: /tmp (scratch) and /app/public
# (empty volume so runtime-config.js can be generated at boot).
# NOTE: /app/public is an EMPTY volume at runtime — baked static assets under
# public/ are shadowed. Keep only generated files here; app static assets are
# served from .next/static (standalone build), not public/.
mkdir -p /tmp /app/public

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
function cap(v, n, fb) { v = String(v != null ? v : fb).slice(0, n); return v || fb; }
const cfg = {
  ENV: cap(process.env.ENV, 128, "dev"),
  VERSION: cap(process.env.VERSION, 128, "1.0.0"),
  BUILD_NUMBER: cap(process.env.BUILD_NUMBER, 128, "0"),
  GIT_COMMIT: cap(process.env.GIT_COMMIT, 128, "unknown"),
  GIT_BRANCH: cap(process.env.GIT_BRANCH, 128, "unknown"),
  GIT_AUTHOR: cap(process.env.GIT_AUTHOR, 256, "unknown"),
  TIMESTAMP: cap(process.env.TIMESTAMP, 128, "unknown"),
  PIPELINE_URL: safeUrl(process.env.PIPELINE_URL, "#"),
};
const js = "window.__RUNTIME_CONFIG__ = " + JSON.stringify(cfg) + ";";
fs.writeFileSync("public/runtime-config.js", js);
// Versioned copy (issue #19): CloudFront never caches /runtime-config*
// (CachingDisabled), but a versioned filename additionally busts any
// downstream/browser cache. Keep the canonical path for backward compat.
try {
  const raw = String(process.env.VERSION || cfg.VERSION || "") + "-" + String(process.env.GIT_COMMIT || cfg.GIT_COMMIT || "");
  const safe = raw.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 64) || "v1";
  fs.writeFileSync("public/runtime-config." + safe + ".js", js);
} catch (e) { /* canonical file already written; versioned copy is best-effort */ }
'

exec node server.js