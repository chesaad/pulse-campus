# Image multi-stage pour le service notif (Go + net/http + client_golang).
# Pas de healthcheck Docker : les probes Kubernetes s'en chargeront.

# ---- Stage 1 : build du binaire ----
FROM golang:1.22-alpine AS build
WORKDIR /src
RUN apk add --no-cache git
COPY go.mod go.sum* ./
COPY cmd/ ./cmd/
# go mod tidy résout les dépendances et écrit go.sum si vide ; permet aux étudiants
# de partir du squelette sans avoir besoin de pré-générer un go.sum localement.
RUN go mod tidy
ARG VERSION=dev
ARG COMMIT=unknown
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.Version=${VERSION} -X main.Commit=${COMMIT}" \
    -o /out/notif ./cmd

# ---- Stage 2 : runtime distroless ----
FROM gcr.io/distroless/static:nonroot AS runtime
LABEL org.opencontainers.image.source="https://github.com/youssef-esgi/pulse-campus"
LABEL org.opencontainers.image.title="notif"
LABEL org.opencontainers.image.description="Service notif — TP DevHub Campus SRE"

WORKDIR /app
COPY --from=build /out/notif /app/notif

# L'image distroless static:nonroot tourne déjà en UID 65532.
# Pour cohérence pédagogique on documente l'utilisateur explicitement.
USER 65532:65532

ENV PORT=8080 \
    LOG_LEVEL=info \
    VERSION=dev \
    COMMIT=unknown \
    METRICS_BUCKETS="0.05,0.1,0.2,0.3,0.5,1,2,5" \
    METRICS_BUSINESS_ENABLED=false

EXPOSE 8080
ENTRYPOINT ["/app/notif"]
