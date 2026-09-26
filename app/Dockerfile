FROM node:26.10-alpine@sha256:0b36e8c136b94cd4fcf02188228e76c31ad5872eef3fec8cbd2eee500cfd9e80 AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts \
 && npm audit signatures \
 && npm audit --audit-level=high
COPY . .
RUN npm run build

FROM node:26.10-alpine@sha256:0b36e8c136b94cd4fcf02188228e76c31ad5872eef3fec8cbd2eee500cfd9e80 AS runner
WORKDIR /app
ENV NODE_ENV=production
# Ephemeral (non-privileged) port so the container can run as a non-root user.
ENV PORT=3000
ENV NODE_OPTIONS="--max-old-space-size=460 --enable-source-maps"
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh && chown -R node:node /app
# Run as an unprivileged user (no root in the container).
USER node
# EXPOSE is doc-only; actual publish via ECS portMappings + ALB SG.
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=60s \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1
CMD ["/app/entrypoint.sh"]