#!/bin/sh
set -e

ENV=${ENV:-dev}
VERSION=${VERSION:-1.0.0}
BUILD_NUMBER=${BUILD_NUMBER:-0}
GIT_COMMIT=${GIT_COMMIT:-unknown}
GIT_BRANCH=${GIT_BRANCH:-unknown}
GIT_AUTHOR=${GIT_AUTHOR:-unknown}
TIMESTAMP=${TIMESTAMP:-unknown}
PIPELINE_URL=${PIPELINE_URL:-#}

cat > public/runtime-config.js <<EOF
window.__RUNTIME_CONFIG__ = {
  ENV: "${ENV} on $(hostname)",
  VERSION: "${VERSION}",
  BUILD_NUMBER: "${BUILD_NUMBER}",
  GIT_COMMIT: "${GIT_COMMIT}",
  GIT_BRANCH: "${GIT_BRANCH}",
  GIT_AUTHOR: "${GIT_AUTHOR}",
  TIMESTAMP: "${TIMESTAMP}",
  PIPELINE_URL: "${PIPELINE_URL}",
};
EOF

exec node server.js
