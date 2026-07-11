# Image multi-stage pour le service planning (Python + FastAPI + prometheus_client).
# Pas de healthcheck Docker : les probes Kubernetes s'en chargeront.

# ---- Stage 1 : build des dépendances ----
FROM python:3.12-slim AS build
WORKDIR /app
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
COPY requirements.txt ./
RUN pip install --prefix=/install -r requirements.txt

# ---- Stage 2 : runtime ----
FROM python:3.12-slim AS runtime
LABEL org.opencontainers.image.source="https://github.com/youssef-esgi/pulse-campus"
LABEL org.opencontainers.image.title="planning"
LABEL org.opencontainers.image.description="Service planning — TP DevHub Campus SRE"

WORKDIR /app
COPY --from=build /install /usr/local
COPY app/ ./app/

# Utilisateur non-root (UID 1001).
RUN groupadd -g 1001 app && useradd -u 1001 -g app -M -s /usr/sbin/nologin app
USER 1001

ENV PORT=8080 \
    LOG_LEVEL=info \
    VERSION=dev \
    COMMIT=unknown \
    METRICS_BUCKETS="0.05,0.1,0.2,0.3,0.5,1,2,5" \
    METRICS_BUSINESS_ENABLED=false

EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
