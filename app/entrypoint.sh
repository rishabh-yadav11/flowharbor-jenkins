#!/bin/sh
set -e

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
'

exec node server.js