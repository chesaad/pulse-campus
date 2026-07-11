"""Middleware Prometheus pour le service planning.

Ce que ce module émet, conforme à la convention RED documentée dans le poly :
    - http_requests_total                  (Counter)
    - http_request_duration_seconds        (Histogram, buckets configurables via env)
    - planning_build_info                  (Gauge constante = 1, métadonnées de release)
    - business_event_total (optionnel)     (Counter, activable par env)

Labels normalisés :
    - method        : GET, POST, PUT, ...
    - route         : pattern de route FastAPI (ex. "/slots/{slot_id}"),
                      JAMAIS l'URL brute, pour ne pas exploser la cardinalité.
    - status_class  : "2xx", "3xx", "4xx", "5xx" — groupé pour la même raison.
"""

from __future__ import annotations

import os
import time
from typing import Callable, List, Tuple

from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response


VERSION = os.getenv("VERSION", "dev")
COMMIT = os.getenv("COMMIT", "unknown")
BUSINESS_ENABLED = os.getenv("METRICS_BUSINESS_ENABLED", "false").lower() == "true"


def _parse_buckets() -> List[float]:
    """Buckets configurables via env METRICS_BUCKETS = "0.05,0.1,0.2,0.3,0.5,1,2,5".

    Les étudiants alignent ces buckets sur leur SLO de latence en étape 2.
    """
    raw = os.getenv("METRICS_BUCKETS", "0.05,0.1,0.2,0.3,0.5,1,2,5")
    parsed: List[float] = []
    for tok in raw.split(","):
        tok = tok.strip()
        if not tok:
            continue
        try:
            v = float(tok)
            if v > 0:
                parsed.append(v)
        except ValueError:
            continue
    return sorted(parsed) if parsed else [0.05, 0.1, 0.2, 0.3, 0.5, 1, 2, 5]


# On utilise un registry dédié pour éviter les collisions avec le registry global
# du process (utile si plusieurs middlewares étaient instanciés en tests).
REGISTRY = CollectorRegistry(auto_describe=True)

HTTP_REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "Nombre total de requêtes HTTP servies.",
    labelnames=["method", "route", "status_class"],
    registry=REGISTRY,
)

HTTP_REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "Durée des requêtes HTTP en secondes.",
    labelnames=["method", "route", "status_class"],
    buckets=_parse_buckets(),
    registry=REGISTRY,
)

BUILD_INFO = Gauge(
    "planning_build_info",
    "Métadonnées de release du service (version, commit, langage). Vaut toujours 1.",
    labelnames=["version", "commit", "language"],
    registry=REGISTRY,
)
BUILD_INFO.labels(version=VERSION, commit=COMMIT, language="python").set(1)

BUSINESS_EVENT_TOTAL = Counter(
    "business_event_total",
    "Compteur d'événements métier applicatifs (activable via METRICS_BUSINESS_ENABLED).",
    labelnames=["kind"],
    registry=REGISTRY,
)


def _status_class(code: int) -> str:
    if code >= 500:
        return "5xx"
    if code >= 400:
        return "4xx"
    if code >= 300:
        return "3xx"
    if code >= 200:
        return "2xx"
    return "1xx"


def _normalize_route(request: Request) -> str:
    """Récupère le pattern FastAPI matché plutôt que l'URL brute.

    Pour Starlette/FastAPI, après le routing, request.scope["route"].path
    contient le pattern (ex. "/slots/{slot_id}"). Si la route n'est pas
    matchée (404), on retombe sur request.url.path — la cardinalité reste
    alors un signal visible plutôt qu'écrasé.
    """
    route = request.scope.get("route")
    if route is not None and getattr(route, "path", None):
        return route.path
    return request.url.path or "unknown"


class PrometheusMiddleware(BaseHTTPMiddleware):
    """Middleware ASGI qui mesure chaque requête HTTP."""

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        # /metrics est servi par la route normale ; pas de mesure récursive.
        if request.url.path == "/metrics":
            return await call_next(request)

        start = time.perf_counter()
        status_code = 500
        try:
            response = await call_next(request)
            status_code = response.status_code
            return response
        finally:
            elapsed = time.perf_counter() - start
            labels = {
                "method": request.method,
                "route": _normalize_route(request),
                "status_class": _status_class(status_code),
            }
            HTTP_REQUESTS_TOTAL.labels(**labels).inc()
            HTTP_REQUEST_DURATION.labels(**labels).observe(elapsed)


def metrics_endpoint() -> Tuple[bytes, str]:
    """Retourne (payload, content-type) pour le endpoint /metrics."""
    return generate_latest(REGISTRY), CONTENT_TYPE_LATEST


def record_business_event(kind: str) -> None:
    if BUSINESS_ENABLED:
        BUSINESS_EVENT_TOTAL.labels(kind=kind).inc()
