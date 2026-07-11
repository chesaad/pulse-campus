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

Piège rencontré en pratique (non documenté dans le poly) : le chart pose par défaut un sous-composant `coreDns` qui crée un `Service` dans le namespace `kube-system` — refusé par notre `AppProject` (destinations volontairement restreintes à `argocd`/`devhub-*`/`monitoring`/`argo-rollouts`, pas `kube-system`). Corrigé en désactivant `coreDns.enabled: false`, pour la même raison que `kubeControllerManager`/`kubeScheduler`/`kubeEtcd`/`kubeProxy` (déjà désactivés dans le squelette) : kind n'expose pas ces endpoints de control-plane de la même façon qu'un vrai cluster managé, et on ne veut de toute façon pas qu'une Application gère des ressources hors de son périmètre.

Second piège rencontré : le squelette suggérait `prometheusOperator.admissionWebhooks.enabled: false` + `patch.enabled: false` ("l'auto-patch peut bloquer sur kind"). Sur la version de chart réellement installée (87.15.1, bien plus récente que la `65.x` supposée par le poly), ce schéma a changé — désactiver purement les admission webhooks laisse le Deployment de l'operator monter un volume `Secret` `kps-admission` que plus rien ne crée, et le pod reste bloqué en `ContainerCreating` indéfiniment (`FailedMount ... secret "kps-admission" not found`). Corrigé en réactivant `enabled: true` + `patch.enabled: true` (le Job de patch génère lui-même un certificat auto-signé, pas besoin de cert-manager sur kind). Preuve que "figer une version de chart" (contrainte de l'étape 3) ne suffit pas — il faut aussi vérifier que les valeurs du poly/squelette correspondent bien au schéma de la version qu'on a réellement figée.

Validation (`kubectl get pods -n monitoring`, `kubectl get pods -n argo-rollouts`) : tous les pods `Running`, les 7 Applications ArgoCD `Synced`/`Healthy` (`root`, `kube-prometheus-stack`, `argo-rollouts`, `dashboards`, `annuaire-dev`, `planning-dev`, `notif-dev`). `Status → Targets` dans Prometheus confirmé via l'API (`/api/v1/targets`) : `annuaire`, `planning`, `notif` et `argo-rollouts-metrics` tous `up`.

---

## Étape 4 — ServiceMonitor + dashboard Grafana par service

`templates/servicemonitor.yaml` ajouté dans les 3 charts (annuaire, planning, **et notif** — bien que non-canary, il est observé comme les deux autres, cf. contrat RED commun). Gabarit identique pour les trois : gated par `.Values.monitoring.enabled`, label `release: {{ .Values.monitoring.serviceMonitor.release }}` sur le ServiceMonitor lui-même (piège n°1 de l'Annexe B du poly — sans ce label, Prometheus l'ignore silencieusement), `namespaceSelector` restreint au namespace du service, endpoint sur le port nommé `http` et le chemin `/metrics`. Activé en dev via `values-dev.yaml` (`monitoring.enabled: true`).

Dashboards (`platform-sre/dashboards/<service>.json`, un par service, gabarit commun) : 4 panneaux minimum comme demandé, templatés par les variables Grafana `$service`, `$namespace`, `$instance` (valeurs par défaut alignées sur le service courant, mais changeables en haut du dashboard pour comparer un autre service/namespace sans dupliquer le JSON) :

| Panneau | PromQL | Ce qu'il sert à voir |
|---|---|---|
| Request rate (RPS) | `sum(rate(http_requests_total{service="$service", namespace="$namespace"}[5m])) by (route)` | Le SLI de trafic — sert de dénominateur à tous les autres SLI (étape 1). Une chute à 0 sans déploiement en cours est le premier signal d'incident. |
| Error rate (5xx %) | `100 * sum(rate(http_requests_total{service="$service", namespace="$namespace", status_class="5xx"}[5m])) / sum(rate(http_requests_total{service="$service", namespace="$namespace"}[5m]))` | Le SLI de disponibilité (étape 1), directement comparable au SLO de 99.5%/99% par service — au-delà de 0.5%/1% en continu, l'error budget mensuel (3h36/7h12) s'érode. |
| Latence p50/p95/p99 | `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{service="$service", namespace="$namespace"}[5m])) by (le))` (×3 pour 0.50/0.95/0.99) | Le p95 est directement le SLI de latence de l'étape 1 (comparé au SLO 300/400/200ms selon le service) ; p50 et p99 donnent le contexte (une p50 stable avec un p99 qui s'envole = une sous-population de requêtes dégradée, pas tout le trafic). |
| Build info (version active) | `{__name__=~"$build_info_metric", namespace="$namespace"}` (table, `instant`) | Le tag d'image actif (`version`, `commit`) par pod — répond à "quelle version tourne réellement là, maintenant" sans avoir à `kubectl describe` chaque pod. |

Nuance sur la réutilisabilité : les 3 premiers panneaux sont génériquement templatés par `$service`/`$namespace` grâce au contrat de labels commun (`http_requests_total`, `http_request_duration_seconds` identiques dans les 3 langages). Le panneau *Build info* ne l'est pas complètement : le nom de la métrique change par service (`annuaire_build_info` / `planning_build_info` / `notif_build_info`), donc une variable Grafana `constant` (`$build_info_metric`) fixe ce nom par dashboard exporté plutôt que de le rendre sélectionnable — un vrai dashboard unique inter-services nécessiterait soit une convention de nommage unique (`build_info{service=...}` sans préfixe), soit une `recording rule` qui uniformise le nom, ce qui n'a pas été fait ici pour rester fidèle à l'instrumentation fournie (« vous n'aurez jamais à la modifier »).

Les dashboards sont commités en JSON pur (source de vérité "exportée") puis enveloppés en `ConfigMap` (label `grafana_dashboard: "1"`) via une petite Kustomization (`platform-sre/dashboards/kustomization.yaml`) déployée par une nouvelle Application ArgoCD `dashboards` — nécessaire car le sidecar de Grafana découvre des `ConfigMap`, pas des fichiers JSON bruts dans Git.

Piège rencontré (le plus instructif du TP jusqu'ici, pas dans l'Annexe B du poly) : le `_helpers.tpl` fourni par le squelette calcule le nom du `Service`/`Deployment`/`ServiceMonitor` comme `{{ .Release.Name }}-{{ .Chart.Name }}`. Comme l'`Application` ArgoCD ne fixe pas de `releaseName` explicite, `.Release.Name` vaut le nom de l'Application (`annuaire-dev`), donc le label Prometheus `service=` valait en réalité `annuaire-dev-annuaire`, pas `annuaire`. Repéré en interrogeant Prometheus directement (`/api/v1/query?query=http_requests_total{namespace="devhub-dev"}`) et en lisant le label `service` retourné — tout le PromQL du rapport (étapes 1 et 4) aurait silencieusement retourné des séries vides en environnement réel. Corrigé en ajoutant le support standard de `fullnameOverride` dans les 3 `_helpers.tpl` (motif `helm create` classique) et en fixant `fullnameOverride: annuaire`/`planning`/`notif` dans chaque `values.yaml` — le nom de Service reste désormais stable quel que soit le nom de release, ce qui est aussi ce qui permettrait de faire tourner le même chart avec un `releaseName` différent en staging/prod sans casser les dashboards.

Validation post-correction (Prometheus interrogé en direct après une salve de `curl` via l'ingress) :

```
$ curl -s --data-urlencode 'query=sum(rate(http_requests_total{namespace="devhub-dev"}[5m]))by(service)' \
    http://localhost:9091/api/v1/query | jq -r '.data.result[] | "\(.metric.service): \(.value[1])"'
annuaire: 0.62
planning: 0.48
notif: 0.46

$ curl -s --data-urlencode 'query=histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{service="annuaire"}[5m])) by (le))' \
    http://localhost:9091/api/v1/query | jq -r '.data.result[] | .value[1]'
0.0475

$ curl -s --data-urlencode 'query=sum(rate(http_requests_total{service="annuaire",status_class!~"5.."}[5m]))/sum(rate(http_requests_total{service="annuaire"}[5m]))' \
    http://localhost:9091/api/v1/query | jq -r '.data.result[] | .value[1]'
1
```

p95 à 47.5 ms (SLO à 300 ms) et disponibilité à 100 % sur du trafic sans erreur injectée — cohérent, sert de baseline "avant canary" pour les étapes suivantes.

---

## Étape 5 — Du Deployment au Rollout

Argo Rollouts installé via l'Application ArgoCD `argo-rollouts` (étape 3), dashboard exposé sur `rollouts.devhub.local`, contrôleur confirmé `Healthy` et son ServiceMonitor scrapé par Prometheus (`argo-rollouts-metrics: up`).

`annuaire` migré : `rollout.yaml` remplace `deployment.yaml` (supprimé du chart, pas conservé en doublon — piège n°1 du poly explicitement évité). Stratégie canary minimaliste, trois étapes simples, pas encore d'`AnalysisTemplate` (étape 7) :

```yaml
strategy:
  canary:
    stableService: annuaire
    canaryService: annuaire-canary
    trafficRouting:
      nginx:
        stableIngress: annuaire
    steps:
      - setWeight: 20
      - pause: { duration: 30s }
      - setWeight: 50
      - pause: { duration: 30s }
      - setWeight: 100
```

`service-stable.yaml` garde le nom `annuaire` (l'`Ingress` existant n'a rien à changer), `service-canary.yaml` ajoute `annuaire-canary`. `trafficRouting.nginx.stableIngress` référence l'Ingress existant : Argo Rollouts fait un **vrai split au niveau requêtes** via `ingress-nginx`, pas une approximation par ratio de replicas.

Déclenchement réel (changement de `image.tag` en dev, commité — cf. contrainte "aucun `kubectl edit`", tout passe par Git) :

```
$ kubectl argo rollouts get rollout annuaire -n devhub-dev
Status:          ॥ Paused
Message:         CanaryPauseStep
Step:            1/5   SetWeight: 20   ActualWeight: 20
Images: ghcr.io/chesaad/annuaire:d45dbf4 (stable), ghcr.io/chesaad/annuaire:d45dbf4-canary-demo (canary)
Replicas: Desired 2, Current 3, Updated 1   # 1 pod canary + 2 pods stable

$ kubectl get ingress annuaire-annuaire-canary -n devhub-dev -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary-weight}'
50   # capturé pendant l'étape 3/5 (SetWeight:50) — confirme un split réel au niveau ingress-nginx,
     # pas seulement au niveau du nombre de pods

# ... 30s plus tard ...
Status: ✔ Healthy   Step: 5/5   SetWeight: 100   ActualWeight: 100
Images: ghcr.io/chesaad/annuaire:d45dbf4-canary-demo (stable)   # promu
```

Défi bonus (résolu en pratique, pas seulement en lecture de doc) — *"inspectez les ressources que crée Argo Rollouts pendant un canary : que voyez-vous d'inattendu ? À quoi sert l'Ingress secondaire ?"* :

```
$ kubectl get ingress -n devhub-dev
NAME                       HOSTS
annuaire                   annuaire.devhub.local   # l'Ingress stable, écrit dans notre chart
annuaire-annuaire-canary   annuaire.devhub.local    # créé DYNAMIQUEMENT par le contrôleur Argo Rollouts, pas dans Git
```

L'Ingress secondaire n'existe pas dans le chart Helm — le contrôleur Argo Rollouts le crée et le détruit lui-même à chaque canary, avec les annotations `nginx.ingress.kubernetes.io/canary: "true"` et `canary-weight: "<N>"`. Il déclare le **même host** que l'Ingress stable : c'est ce doublon volontaire qui permet à `ingress-nginx` de router une fraction des requêtes vers le Service canary sans jamais toucher au DNS ni à l'Ingress stable lui-même — la mécanique documentée dans *Traffic Management with NGINX Ingress*.

Piège rencontré et corrigé : après la migration, l'ancien `Deployment/annuaire` restait dans le cluster (l'Application a `prune: false`, cf. étape 3) — exactement le piège n°1 du poly ("deux ReplicaSets qui se battent pour les pods"). Supprimé manuellement (`kubectl delete deployment annuaire -n devhub-dev`), puisqu'il était strictement remplacé par le Rollout du même nom déjà `Healthy`.

Second piège, non documenté dans le poly : après la migration, l'Application `annuaire-dev` restait perpétuellement `OutOfSync` malgré un état fonctionnellement identique. Diagnostiqué avec `argocd app manifests --core --source=git` vs `--source=live` : l'API Kubernetes défaultait silencieusement `protocol: TCP` sur le port du conteneur côté live. ArgoCD normalise ce genre de default connu pour les types natifs (`Deployment`), mais pas pour un champ de forme `PodSpec` imbriqué dans une CRD (`Rollout`). Corrigé en déclarant `protocol: TCP` explicitement dans `rollout.yaml` — plus généralement, une leçon pour la suite du TP : sur une CRD, il faut s'attendre à devoir déclarer explicitement des champs qu'on omettrait sans risque sur une ressource native.

Validation : dashboard `rollouts.devhub.local` (Argo Rollouts) affiche le Rollout ; canary observé de bout en bout par `--watch`, capture ci-dessus.

---
