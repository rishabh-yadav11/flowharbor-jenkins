#!/bin/sh
set -e

# Build runtime config using Node's JSON.stringify so every value is properly
# escaped before being embedded into a <script>. Naive shell interpolation
# here is an XSS vector (a hostile GIT_TAG/URL could break out of the string
# and inject arbitrary JavaScript served to every visitor).
node -e '
const fs = require("fs");
const cfg = {
  ENV: process.env.ENV || "dev",
  VERSION: process.env.VERSION || "1.0.0",
  BUILD_NUMBER: process.env.BUILD_NUMBER || "0",
  GIT_COMMIT: process.env.GIT_COMMIT || "unknown",
  GIT_BRANCH: process.env.GIT_BRANCH || "unknown",
  GIT_AUTHOR: process.env.GIT_AUTHOR || "unknown",
  TIMESTAMP: process.env.TIMESTAMP || "unknown",
  PIPELINE_URL: process.env.PIPELINE_URL || "#",
};
const js = "window.__RUNTIME_CONFIG__ = " + JSON.stringify(cfg) + ";";
fs.writeFileSync("public/runtime-config.js", js);
'

exec node server.js