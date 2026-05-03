# syntax=docker/dockerfile:1.7
ARG NODE_VERSION=20-alpine
ARG CADDY_VERSION=2-alpine

FROM node:${NODE_VERSION} AS builder
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@9 --activate

# Install deps with cached layer
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# Build
COPY . .
ARG VITE_API_BASE_URL=/api
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}
RUN pnpm build

# Runtime
FROM caddy:${CADDY_VERSION} AS runner
COPY --from=builder /app/dist /srv
COPY Caddyfile /etc/caddy/Caddyfile
EXPOSE 8080
# Caddy default CMD picks up /etc/caddy/Caddyfile
