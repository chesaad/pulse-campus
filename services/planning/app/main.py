"""Service planning — application FastAPI minimaliste.

CRUD en mémoire sur des créneaux (slots). Aucune persistance, aucune base :
l'objectif du TP est sur l'observabilité, pas sur le stockage.

Ce module configure :
    - le middleware Prometheus (cf. app/metrics.py) ;
    - quelques routes métier (/slots, /slots/{slot_id}) ;
    - les routes /healthz et /metrics requises par Kubernetes et Prometheus.
"""

from __future__ import annotations

import os
import random
from typing import Dict, List

from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

from app.metrics import (
    metrics_endpoint,
    PrometheusMiddleware,
    record_business_event,
)


FAIL_RATE = float(os.getenv("FAIL_RATE", "0"))  # 0..1 — pour tester un canary KO en étape 7

app = FastAPI(title="planning", version=os.getenv("VERSION", "dev"))

# Le middleware Prometheus DOIT être enregistré avant les routes.
app.add_middleware(PrometheusMiddleware)


# Données métier en mémoire — volontairement minimalistes.
class Slot(BaseModel):
    id: int
    salle: str
    debut: str  # ISO8601
    fin: str


_slots: List[Dict] = [
    {"id": 1, "salle": "A101", "debut": "2026-01-15T09:00:00", "fin": "2026-01-15T11:00:00"},
    {"id": 2, "salle": "A102", "debut": "2026-01-15T13:30:00", "fin": "2026-01-15T15:30:00"},
    {"id": 3, "salle": "B201", "debut": "2026-01-16T08:00:00", "fin": "2026-01-16T10:00:00"},
]


@app.get("/slots")
def list_slots():
    record_business_event("list_slots")
    return _slots


@app.get("/slots/{slot_id}")
def get_slot(slot_id: int):
    for s in _slots:
        if s["id"] == slot_id:
            return s
    raise HTTPException(status_code=404, detail="not_found")


@app.post("/slots", status_code=201)
def create_slot(slot: Slot):
    if any(s["id"] == slot.id for s in _slots):
        raise HTTPException(status_code=409, detail="id_already_used")
    _slots.append(slot.model_dump())
    record_business_event("create_slot")
    return {"id": slot.id}


# Endpoint utilisé en étape 7 pour simuler une régression.
@app.get("/break")
def break_endpoint():
    if random.random() < FAIL_RATE:
        raise HTTPException(status_code=500, detail="boom")
    return {"ok": True}


# Probes Kubernetes.
@app.get("/healthz")
def healthz():
    return {"ok": True, "service": "planning"}


@app.get("/readyz")
def readyz():
    return {"ok": True, "service": "planning"}


# Endpoint Prometheus — délégué à app/metrics.py.
@app.get("/metrics")
def metrics():
    body, content_type = metrics_endpoint()
    return Response(content=body, media_type=content_type)
