FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
# Ephemeral (non-privileged) port so the container can run as a non-root user.
ENV PORT=3000
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh && chown -R node:node /app
# Run as an unprivileged user (no root in the container).
USER node
EXPOSE 3000
CMD ["/app/entrypoint.sh"]