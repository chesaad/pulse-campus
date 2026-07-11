# RAPPORT.md — TP3 : Livraison progressive et observabilité (DevHub Campus SRE)

Binôme : chesaad
Dépôt : https://github.com/chesaad/pulse-campus
Cluster : `kind-devhub` (réutilisé depuis le TP2, ArgoCD déjà opérationnel — cf. avant-propos du poly, "un cluster ArgoCD opérationnel suffit")

---

## Outillage TP 3 (Étape 0)

Installés localement (aucun outil dans le cluster à cette étape) :

```
$ kubectl argo rollouts version
kubectl-argo-rollouts: v1.9.0+838d4e7
  BuildDate: 2026-03-20T21:11:48Z
  GoVersion: go1.24.13
  Platform: darwin/amd64

$ promtool --version
promtool, version 3.13.1
  go version: go1.26.5
  platform: darwin/arm64

$ amtool --version
amtool, version 0.28.0
  platform: darwin/arm64

$ jq --version
jq-1.7.1
```

Piège évité : `kubectl-argo-rollouts` est un plugin kubectl (installé via `argoproj/tap`), pas une CLI standalone — on l'appelle `kubectl argo rollouts ...`, jamais `argo-rollouts ...`. `amtool` n'est plus distribué par un formula Homebrew séparé ; binaire récupéré depuis la release GitHub officielle `prometheus/alertmanager` (optionnel selon le poly, installé quand même pour l'étape 10).

## Étape 1 — SLI, SLO, error budget

Le calcul d'error budget suppose un mois de 30 jours = 43 200 minutes.

| Service | SLI | SLO | Error budget mensuel |
|---|---|---|---|
| annuaire | Disponibilité (requêtes non-5xx / total) | 99.5 % tenu sur fenêtre glissante 30j | 43 200 × 0.5 % = **216 min (3h36)** |
| annuaire | Latence p95 des requêtes | < 300 ms sur fenêtre 5 min | (métrique binaire bonne/mauvaise minute) 216 min/mois où p95 peut dépasser 300ms |
| annuaire | Fraîcheur des données (âge du dernier `annuaire_build_info` scrape vs déploiement) | dernier déploiement < 15 min après merge sur main | 216 min/mois de retard cumulé tolérable |
| planning | Disponibilité | 99.5 % sur 30j | 216 min (3h36) |
| planning | Latence p95 | < 400 ms sur 5 min (FastAPI + I/O slots, plus lourd qu'annuaire — cf. `resources.requests.memory` 2x supérieur dans values.yaml) | 216 min/mois |
| planning | Taux de succès de création de créneaux (`business_event_total{kind="create_slot"}` vs tentatives POST /slots) | 99 % sur 30j | 432 min (7h12) |
| notif | Disponibilité | 99 % sur 30j (service non critique du parcours étudiant, déploiement encore en Deployment classique, pas de canary) | 432 min (7h12) |
| notif | Latence p95 | < 200 ms sur 5 min (service léger, `resources.requests` les plus faibles des trois) | 432 min/mois |
| notif | Taux de succès de création d'événements (`business_event_total{kind="create_event"}` vs tentatives POST /events) | 99.5 % sur 30j | 216 min (3h36) |

Justification des seuils : 99.5 % (pas 99.9 %) car un cluster kind local avec 3 services jouets n'a pas la même exigence qu'une plateforme critique — un SLO trop strict ne serait jamais respecté et rendrait l'error budget en permanence négatif, donc inutile comme signal de décision (piège explicitement cité dans le poly). `notif` a un SLO de disponibilité plus lâche (99 % vs 99.5 %) car c'est le seul service resté en simple `Deployment` — cohérent avec son rôle de baseline de comparaison, pas de canary/rollback automatique pour le protéger.

PromQL pseudo-code (à la main, un exemple par service — le reste suit le même patron avec `service="planning"` / `service="notif"`) :

```promql
# Disponibilité (annuaire)
sum(rate(http_requests_total{service="annuaire", status_class!~"5.."}[5m]))
/
sum(rate(http_requests_total{service="annuaire"}[5m]))

# Latence p95 (annuaire)
histogram_quantile(
  0.95,
  sum(rate(http_request_duration_seconds_bucket{service="annuaire"}[5m])) by (le)
)

# Taux de succès de création de créneaux (planning)
sum(rate(business_event_total{service="planning", kind="create_slot"}[30d]))
/
sum(rate(http_requests_total{service="planning", route="/slots", method="POST"}[30d]))

# Taux de succès de création d'événements (notif)
sum(rate(business_event_total{service="notif", kind="create_event"}[30d]))
/
sum(rate(http_requests_total{service="notif", route="/events", method="POST"}[30d]))
```

Validation orale (formateur) : *« pour annuaire, l'error budget est de 216 minutes par mois. Si on l'épuise en deux semaines, je regarde d'abord les déploiements récents via `kubectl argo rollouts get rollout annuaire` — un canary récent est le suspect n°1 — puis je fige les déploiements non critiques jusqu'à la fin du mois calendaire tout en priorisant un correctif sur la cause identifiée. »*

---

## Étape 2 — Buckets d'histogramme configurés

`chart/values.yaml` de chaque service, clé `metrics.buckets` :

| Service | SLO p95 | Buckets (`metrics.buckets`) | `businessEnabled` |
|---|---|---|---|
| annuaire | < 300 ms | `0.05,0.1,0.2,0.3,0.5,1,2,5` (défaut déjà exact à 0.3) | false |
| planning | < 400 ms | `0.05,0.1,0.2,0.3,0.4,0.5,0.75,1,2,5` (bucket exact ajouté à 0.4) | true |
| notif | < 200 ms | `0.01,0.025,0.05,0.1,0.2,0.3,0.5,1,2` (résolution fine sous 0.2, bucket exact à 0.2, `notif` étant le service le plus léger — `resources.requests.cpu: 25m` vs 50m pour les deux autres) | true |

Pour planning et notif, `businessEnabled: true` car les SLO de l'étape 1 s'appuient sur `business_event_total{kind="create_slot"}` / `kind="create_event"}` pour mesurer un taux de succès métier, pas seulement la disponibilité HTTP.

Validation locale (`docker build` + `docker run` + `curl` + `promtool check metrics`, un exemple représentatif — annuaire) :

```
$ docker run -d -p 8081:8080 -e METRICS_BUCKETS="0.05,0.1,0.2,0.3,0.5,1,2,5" -e METRICS_BUSINESS_ENABLED=true annuaire:local
$ curl -s localhost:8081/students >/dev/null && curl -s -X POST localhost:8081/students -d '{"name":"Test"}' >/dev/null
$ curl -s localhost:8081/metrics | grep -E "http_request_duration_seconds_bucket|annuaire_build_info|business_event_total"
http_requests_total{method="GET",route="/students",status_class="2xx"} 1
http_request_duration_seconds_bucket{le="0.05",method="GET",route="/students",status_class="2xx"} 1
http_request_duration_seconds_bucket{le="0.1",...} 1
http_request_duration_seconds_bucket{le="0.2",...} 1
http_request_duration_seconds_bucket{le="0.3",...} 1     # ← bucket exact au seuil SLO p95
http_request_duration_seconds_bucket{le="0.5",...} 1
http_request_duration_seconds_bucket{le="1",...} 1
http_request_duration_seconds_bucket{le="2",...} 1
http_request_duration_seconds_bucket{le="5",...} 1
http_request_duration_seconds_bucket{le="+Inf",...} 1
annuaire_build_info{version="dev",commit="unknown",language="nodejs"} 1
business_event_total{kind="list_students"} 1

$ curl -s localhost:8081/metrics | promtool check metrics
nodejs_active_handles_total non-counter metrics should not have "_total" suffix
nodejs_active_requests_total non-counter metrics should not have "_total" suffix
nodejs_active_resources_total non-counter metrics should not have "_total" suffix
```

Les 3 warnings viennent des métriques par défaut de `prom-client` (`collectDefaultMetrics`, process Node.js) — pas du code écrit dans ce TP, aucune métrique applicative (`http_requests_total`, `http_request_duration_seconds`, `annuaire_build_info`, `business_event_total`) n'est signalée. Même vérification faite (sans erreur) sur `planning:local` (buckets `le="0.4"` confirmé, `planning_build_info`, `business_event_total{kind="list_slots"}`) et `notif:local` (buckets `le="0.2"` confirmé, `notif_build_info`, `business_event_total{kind="list_events"}`).

---

## Étape 3 — kube-prometheus-stack via ArgoCD

TODOs résolus dans `platform-sre/` :

- `repoURL` aligné sur `https://github.com/chesaad/pulse-campus.git` partout (root, AppProject, les 2 Applications observability, les 3 Applications dev).
- `AppProject.spec.sourceRepos` restreint à trois entrées explicites (pas de `"*"`) : le fork Git, `prometheus-community/helm-charts`, `argoproj/argo-helm` — nécessaires car `kube-prometheus-stack.yaml` et `argo-rollouts.yaml` sont des Applications **multi-source** (chart distant + values de ce repo), et `sourceRepos` s'applique à toutes les sources, pas seulement au repo Git principal.
- `AppProject.spec.clusterResourceWhitelist` complété avec `ClusterRole`, `ClusterRoleBinding`, `MutatingWebhookConfiguration`, `ValidatingWebhookConfiguration`, `APIService` — sans ça ArgoCD refuse de créer les RBAC et webhooks posés par `kube-prometheus-stack` (CRD `prometheusOperator`) et potentiellement par `argo-rollouts`.
- Root `syncPolicy` : `selfHeal: true`, `prune: false` — même choix qu'au TP2 (cf. commentaire dans `root-app.yaml`) : la root est le point d'entrée unique de la plateforme, un edit manuel dessus doit être corrigé automatiquement, mais un chemin mal tapé ne doit jamais supprimer toutes les Applications enfants d'un coup.
- Versions de chart figées après vérification `helm search repo --versions` (2026-07-11) : `kube-prometheus-stack` → `87.15.1`, `argo-rollouts` → `2.41.0` (aligné avec le plugin `kubectl-argo-rollouts` v1.9.0 installé en étape 0, même `appVersion`).
- `retry.limit: 5` activé sur l'Application `kube-prometheus-stack` : le chart pose ~60 CRDs, la première synchro sur un cluster kind (I/O disque limité) peut dépasser le timeout par défaut d'ArgoCD.
- Mot de passe admin Grafana : **jamais en clair dans Git**. `grafana.admin.existingSecret: grafana-admin-credentials` référence un Secret créé hors-Git :

```
$ kubectl create namespace monitoring
$ kubectl create secret generic grafana-admin-credentials -n monitoring \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 18)"
secret/grafana-admin-credentials created
```

  Mot de passe récupérable à tout moment avec `kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d` (volontairement non affiché ici pour ne pas committer un secret dans un rapport versionné).
- ServiceMonitor du contrôleur Argo Rollouts activé (`controller.metrics.serviceMonitor.enabled: true` + label `release: kps`) pour que Prometheus le scrape dès l'étape 5 — non explicitement marqué TODO dans le squelette mais nécessaire à la cohérence (`serviceMonitorSelector.matchLabels.release: kps` dans `kube-prometheus-stack-values.yaml`).

Piège du poly explicitement anticipé : le chart `kube-prometheus-stack` pose beaucoup de CRDs, un `OutOfSync` après le premier sync est souvent dû à un mismatch d'`apiVersion` — `ServerSideApply=true` dans `syncOptions` (déjà présent dans le squelette) est la parade documentée dans les notes de version du chart.

---
