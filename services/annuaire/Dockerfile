# Image multi-stage pour le service annuaire (Node.js + Express + prom-client).
# Pas de healthcheck Docker : les probes Kubernetes s'en chargeront.

# ---- Stage 1 : install des dépendances ----
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
# `npm install` plutôt que `npm ci` car on n'embarque pas de lockfile dans le squelette.
RUN npm install --omit=dev && npm cache clean --force
COPY src/ ./src/

# ---- Stage 2 : runtime ----
FROM node:20-alpine AS runtime
LABEL org.opencontainers.image.source="https://github.com/youssef-esgi/pulse-campus"
LABEL org.opencontainers.image.title="annuaire"
LABEL org.opencontainers.image.description="Service annuaire — TP DevHub Campus SRE"

WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/src ./src
COPY package.json ./

# Utilisateur non-root (UID 1001).
RUN addgroup -g 1001 -S app && adduser -u 1001 -S app -G app
USER 1001

ENV PORT=8080 \
    LOG_LEVEL=info \
    NODE_ENV=production \
    VERSION=dev \
    COMMIT=unknown \
    METRICS_BUCKETS="0.05,0.1,0.2,0.3,0.5,1,2,5" \
    METRICS_BUSINESS_ENABLED=false

EXPOSE 8080
CMD ["node", "src/index.js"]
