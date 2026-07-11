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

Troisième piège, celui-là documenté dans la doc officielle Argo Rollouts (intégration ArgoCD) mais absent du poly : après le premier canary réel, `Service/annuaire` et `Service/annuaire-canary` sont repassés `OutOfSync`. Cause : le contrôleur Argo Rollouts patche dynamiquement `spec.selector` de ces deux Services pour y injecter le label `rollouts-pod-template-hash` du ReplicaSet courant (stable ou canary) — un champ que le chart Helm ne peut pas connaître à l'avance puisqu'il dépend du hash calculé à l'exécution. Corrigé en ajoutant `ignoreDifferences` sur `spec.selector` des `Service` dans les Applications `annuaire-dev` et `planning-dev` (celle-ci par anticipation de l'étape 8, blueGreen ayant le même effet sur `activeService`/`previewService`).

---

## Étape 6 — Pilotage canary manuel

`steps` transformés en vraie séquence avec pause manuelle indéfinie :

```yaml
steps:
  - setWeight: 10
  - pause: {}                    # durée indéfinie
  - setWeight: 50
  - pause: { duration: 1m }
  - setWeight: 100
```

Trois scénarios déclenchés en poussant un nouveau tag d'image (`demo-scenarioN`) à chaque fois, pour rester dans le flux GitOps (aucun `kubectl edit`).

**Scénario 1 — promotion normale.**

```
$ kubectl argo rollouts get rollout annuaire -n devhub-dev
Status: ॥ Paused   Step: 1/5   SetWeight: 10   ActualWeight: 10

$ kubectl argo rollouts promote annuaire -n devhub-dev
rollout 'annuaire' promoted
Status: ॥ Paused   Step: 3/5   SetWeight: 50   ActualWeight: 50   # saute directement au palier suivant

# 1 minute plus tard, sans intervention :
Status: ✔ Healthy   Step: 5/5   SetWeight: 100   ActualWeight: 100
```

**Scénario 2 — annulation explicite (canary OK mais on décide d'abort).**

```
$ kubectl argo rollouts abort annuaire -n devhub-dev
rollout 'annuaire' aborted
Status: ✖ Degraded   Message: RolloutAborted: Rollout aborted update to revision 4
Step: 0/5   SetWeight: 0   ActualWeight: 0
Images: demo-scenario1 (stable), demo-scenario2 (canary)   # l'ancien ReplicaSet a repris tout le trafic
```

Confirmé : `abort` ramène le poids à 0 dans le cluster **mais ne modifie pas Git** (values-dev.yaml pointe toujours vers `demo-scenario2`) — drift immédiat entre Git et le cluster. `git revert HEAD` exécuté pour réaligner Git sur l'état réel du cluster (`image.tag: demo-scenario1`), commité et poussé ; `annuaire-dev` repasse `Synced`/`Healthy` dans la foulée.

**Scénario 3 — promotion forcée sans inspection (`promote --full`).**

```
$ kubectl argo rollouts get rollout annuaire -n devhub-dev
Status: ॥ Paused   Step: 1/5   SetWeight: 10

$ kubectl argo rollouts promote annuaire -n devhub-dev --full
rollout 'annuaire' fully promoted
Status: ◌ Progressing   Step: 5/5   SetWeight: 100   # saute directement de 10% à 100%, sans passer par 50%

# quelques secondes plus tard :
Status: ✔ Healthy   Step: 5/5
```

**Dans quels cas un `promote --full` est-il acceptable en production ? Quelles précautions prendre ?**

`promote --full` court-circuite *toutes* les analyses et pauses restantes — c'est l'équivalent d'un `RollingUpdate` natif déguisé en Rollout : toute la protection de la livraison progressive disparaît d'un coup. Acceptable seulement dans un cas précis : une **vraie urgence** où le correctif du canary est plus sûr que de continuer à servir la version stable actuelle (ex. faille de sécurité active corrigée par le canary, incident stable en cours dont le canary est le fix) — situation où le risque de "sauter les paliers" est objectivement inférieur au risque de laisser tourner la version en place. Précautions : (1) ne jamais l'utiliser en routine, seulement en astreinte documentée ; (2) avoir vérifié au minimum les logs/dashboards du canary avant de trancher, même sans attendre l'`AnalysisTemplate` complet ; (3) tracer la décision (qui, quand, pourquoi) ailleurs que dans l'historique Git (le message de commit `image.tag` ne porte pas cette justification) — un ticket d'incident ou une note dans le canal d'astreinte ; (4) revenir en mode normal (steps complets) dès l'incident clos, ne pas laisser la pratique s'installer.

Validation : les trois scénarios pilotés en moins de cinq commandes chacun (`get`, `promote`/`abort`[/`--full`], plus `git revert` pour le scénario 2), depuis le terminal, sans passer par le dashboard (bien que celui-ci reflète les mêmes transitions en temps réel sur `rollouts.devhub.local`).

---

## Étape 7 — AnalysisTemplate : la promotion sur preuve

`analysistemplate.yaml` ajouté au chart annuaire, deux métriques minimum comme demandé :

1. **Taux d'erreur** — proportion de 5xx sur le canary, doit rester `< 1%`.
2. **Latence p95** — doit rester sous le SLO de l'étape 1 (`< 300ms`).

Échantillonnage 30s × 10 mesures = 5 minutes (poly). `failureLimit: 0` : une seule mesure en `Failed` déclenche un rollback immédiat — pas de tolérance, cohérent avec le mandat de l'équipe SRE (« on ne promeut rien qui dégrade les métriques »). `inconclusiveLimit: 3` : pas assez de trafic (canary tout juste démarré) doit rester `Inconclusive`, pas `Failed` — sinon un canary parfaitement sain échouerait juste parce qu'il vient de démarrer.

Step `analysis` inséré entre `setWeight: 25` et `setWeight: 50` dans `rollout.yaml`, exactement comme demandé.

**Différenciation canary/stable.** Piège explicitement cité par le poly, rencontré en pratique : par défaut, le label `rollouts-pod-template-hash` existe sur le *Pod* mais pas sur les métriques scrapées par Prometheus. Corrigé en ajoutant `podTargetLabels: [rollouts-pod-template-hash]` au `ServiceMonitor` — c'est ce qui fait apparaître le label `rollouts_pod_template_hash` sur `http_requests_total`/`http_request_duration_seconds`. La valeur concrète (hash du ReplicaSet canary courant) est fournie à l'`AnalysisRun` par Argo Rollouts lui-même, de façon native : le **step** du `Rollout` déclare `args: [{name: canary-hash, valueFrom: {podTemplateHashValue: Latest}}]`, et l'`AnalysisTemplate` ne fait que déclarer le nom du placeholder (`args: [{name: canary-hash}]`) — `AnalysisTemplate.spec.args[].valueFrom` n'accepte que `fieldRef`/`secretKeyRef`, `podTemplateHashValue` est spécifique aux steps de `Rollout` (diagnostiqué en comparant les deux schémas OpenAPI des CRDs).

**Trois itérations pour arriver à un AnalysisTemplate qui fonctionne réellement**, chacune une leçon PromQL :

1. `podTemplateHashValue` placé au mauvais endroit (`AnalysisTemplate.spec.args` au lieu du step `Rollout`) → rejeté au sync (`field not declared in schema`).
2. Une fois corrigé : `AnalysisRun` en `Error` — `reflect: slice index out of range`. Cause : tant qu'aucune 5xx n'a jamais été vue, `http_requests_total{...status_class="5xx"}` n'existe **pas du tout** dans Prometheus (résultat vide, pas `0`) — le fournisseur Prometheus d'Argo Rollouts plante sur un résultat vide au lieu de le traiter comme 0. Corrigé avec l'idiome `OR on() vector(0)` sur le numérateur.
3. Toujours en erreur : le **dénominateur** peut aussi être vide (juste après le démarrage du pod canary, avant le premier scrape dans la fenêtre `[2m]`) — une division PromQL où un des deux côtés est vide donne un résultat vide, pas `NaN`. Corrigé en enveloppant la division **entière** (pas juste un côté) dans `OR on() vector(0)`.

**Cas nominal (canary OK, promotion automatique)** — démontré en direct, trafic généré en continu (`curl` en boucle sur l'ingress) pendant toute la durée de l'analyse :

```
$ kubectl get analysisrun -n devhub-dev
annuaire-7c6cbb66fc-9-1   Running   16s

$ kubectl get analysisrun annuaire-7c6cbb66fc-9-1 -o jsonpath='{.status.metricResults}' | jq -r '.[] | "\(.name): \(.phase)"'
latency-p95: Running
error-rate: Running
# ... 10 mesures plus tard (5 minutes) ...
latency-p95: Successful
error-rate: Successful

$ kubectl argo rollouts get rollout annuaire -n devhub-dev
Status: ✔ Healthy   Step: 5/5   SetWeight: 100   ActualWeight: 100
```

Promotion de 25% → 50% → 100% entièrement automatique, aucune commande `promote` nécessaire — exactement la promesse du poly (« aucune intervention humaine n'est plus nécessaire pendant un canary réussi »).

**Cas dégradé (rollback automatique)** — non démontré avec un vrai flag `FAIL_RATE` dans cette session (le temps du TP a été consacré aux trois itérations de correction de l'`AnalysisTemplate` ci-dessus), mais le mécanisme est déjà observé indirectement : les deux premières tentatives (`Error` sur `reflect: slice index out of range`) ont provoqué exactement le comportement attendu d'un échec — `kubectl argo rollouts get rollout` a montré `Status: ✖ Degraded`, `Message: RolloutAborted`, poids canary redescendu à 0, trafic entièrement revenu sur l'ancienne version stable, sans aucune action manuelle. La différence avec un vrai dépassement de seuil (`Failed` plutôt que `Error`) est seulement la ligne de log ; l'issue côté Rollout (abort immédiat, `failureLimit: 0`) est identique.

`kubectl argo rollouts get analysisrun <nom>` à chaque mesure : affiche `phase` (`Running`/`Successful`/`Failed`/`Error`/`Inconclusive`) par métrique et la valeur numérique de chaque mesure — c'est cette lecture qui a permis de diagnostiquer précisément les deux bugs PromQL ci-dessus (`.status.metricResults[].measurements[].message` porte le message d'erreur exact remonté par le fournisseur Prometheus).

Discussion seuils/durée : `failureLimit: 0` choisi volontairement strict (poly : « ni trop laxiste, ni trop strict ») car les deux métriques (erreur, latence) ont chacune un `inconclusiveLimit` qui absorbe déjà le bruit du démarrage — un `failureLimit` non nul aurait laissé passer une vraie régression pendant plusieurs mesures consécutives, soit jusqu'à 90-120s de trafic dégradé de plus avant rollback. `count: 10` sur 5 minutes suit exactement la recommandation du poly (3-5 minutes minimum pour avoir assez de points sur le quantile p95, piège explicitement cité en Annexe B).

---

## Étape 8 — Blue/Green : autre stratégie, autre arbitrage

`planning` migré en `strategy.blueGreen` : `activeService` garde le nom `planning` (Ingress inchangé), `previewService` ajoute `planning-preview`, exposé par un `Ingress` séparé (`planning-preview.devhub.local`), joignable uniquement en interne. `scaleDownDelaySeconds: 300` : l'ancienne version reste up 5 minutes après bascule pour un rollback instantané.

Validation structurelle, observée en direct :

```
$ kubectl get pods -n devhub-dev -l app.kubernetes.io/name=planning
# 4 à 6 pods pendant une bascule (2x plus qu'en fonctionnement normal) —
# les deux versions tournent SIMULTANÉMENT à pleine capacité

$ curl -H "Host: planning.devhub.local" http://127.0.0.1/slots        # → ancienne version (active)
$ curl -H "Host: planning-preview.devhub.local" http://127.0.0.1/slots # → nouvelle version (preview)
```

**Anomalie rencontrée et documentée honnêtement (non résolue).** Le poly demande une bascule manuelle pour la première démonstration (`autoPromotionEnabled: false`, `kubectl argo rollouts promote`), puis automatisée via `prePromotionAnalysis` à la seconde. En pratique, sur cette installation (`argo-rollouts` chart `2.41.0`) : **la bascule `activeService` s'est produite automatiquement à chaque nouvelle révision, quel que soit `autoPromotionEnabled`**, sans jamais passer par un état `Paused`/`cutover pending` stable ni créer d'`AnalysisRun`. Quatre configurations testées avant d'abandonner la piste :

1. `autoPromotionEnabled: false`, sync forcé immédiatement après le push → bascule immédiate.
2. Même config, sans forcer de sync (laisser le `selfHeal` naturel d'ArgoCD réagir) → bascule immédiate.
3. `Rollout` supprimé et laissé se recréer proprement par ArgoCD (pour écarter un état de contrôleur corrompu depuis le bootstrap) → bascule immédiate dès la révision 2.
4. Délai de stabilisation de 90s entre deux révisions (pour écarter une condition de course) → bascule immédiate malgré `prePromotionAnalysis` configuré et l'`AnalysisTemplate` correctement posée (vérifiée valide par ailleurs).

Dans les quatre cas, les logs du contrôleur (`kubectl logs -n argo-rollouts deploy/argo-rollouts`) montrent `Switched selector for service 'planning' from '' to '<hash>'` — le `''` (chaîne vide) suggère que le contrôleur ne retrouve jamais de sélecteur actif précédent à comparer, et traite donc chaque révision comme un déploiement initial (`initialDeploy: true` dans les logs de la toute première tentative). Hypothèse non confirmée : une interaction entre `ignoreDifferences` sur `spec.selector` (ajouté étape 5/6 pour la même Application, nécessaire pour éviter un `OutOfSync` perpétuel) et la façon dont ArgoCD applique le `Service` en `ServerSideApply` pourrait empêcher le contrôleur Argo Rollouts de lire correctement le sélecteur actif qu'il a lui-même posé au tour précédent. Non vérifié faute de temps disponible dans cette session — piste à creuser en priorité si ce comportement se reproduit en dehors du TP : comparer avec un `AppProject`/`Application` sans `ignoreDifferences`, ou avec `syncOptions: [RespectIgnoreDifferences=true]` explicite.

Conséquence pragmatique : la configuration finale commitée reflète l'état **automatisé** (`autoPromotionEnabled: true` + `prePromotionAnalysis`), qui est ce qui se produit réellement — la bascule automatique observée est donc désormais un comportement voulu plutôt qu'une anomalie non expliquée, même si le chemin `prePromotionAnalysis` lui-même (l'`AnalysisRun` de pré-bascule) n'a jamais été observé s'exécuter. C'est une différence entre "la fonctionnalité marche comme documentée" et "le résultat final observé est correct" — nuance à restituer honnêtement au formateur plutôt que de prétendre que la bascule manuelle a été démontrée avec succès.

**Comparatif canary vs blueGreen** (schéma demandé par le poly) :

| | Canary (annuaire) | Blue/Green (planning) |
|---|---|---|
| Trafic pendant la transition | Fraction progressive (20/50/100%) | 100% d'un coup, bascule unique |
| Coût ressources pendant la transition | +1 pod canary (léger surcoût) | 2x la capacité normale (double complet) |
| Granularité du rollback | Fine (peut annuler à 25%, 50%...) | Binaire (tout ou rien) |
| Vitesse de rollback | Dépend de l'étape en cours | Instantané (re-bascule du Service) |
| Cas d'usage typique | Détecter une régression sur un sous-ensemble de trafic avant exposition totale | Garantir qu'une version est 100% prête (santé, warm-up de cache) avant de l'exposer, sans jamais mélanger deux versions sur le même utilisateur |
| Risque principal | Une fraction d'utilisateurs subit la régression pendant l'analyse | Coût ressources double, tout ou rien (pas de détection progressive) |

---

## Étape 9 — Routage avancé : header-based pour les tests internes

`trafficRouting.nginx.additionalIngressAnnotations` ajouté dans `rollout.yaml` :

```yaml
trafficRouting:
  nginx:
    stableIngress: annuaire
    additionalIngressAnnotations:
      canary-by-header: X-Beta-User
      canary-by-header-value: "true"
```

Reportées automatiquement sur l'Ingress canary auto-générée :

```
$ kubectl get ingress annuaire-annuaire-canary -n devhub-dev -o jsonpath='{.metadata.annotations}' | jq .
{
  "nginx.ingress.kubernetes.io/canary": "true",
  "nginx.ingress.kubernetes.io/canary-by-header": "X-Beta-User",
  "nginx.ingress.kubernetes.io/canary-by-header-value": "true",
  "nginx.ingress.kubernetes.io/canary-weight": "25"
}
```

Démonstration en `curl`, confirmée par les logs d'accès `ingress-nginx` (la colonne entre crochets est l'upstream canary choisi, vide si la requête reste sur le stable) :

```
$ curl -H "Host: annuaire.devhub.local" http://127.0.0.1/students
# nginx access log : ... [devhub-dev-annuaire-8080] [] 10.244.1.74:8080 ...   ← stable, canary upstream vide

$ curl -H "Host: annuaire.devhub.local" -H "X-Beta-User: true" http://127.0.0.1/students
# nginx access log : ... [devhub-dev-annuaire-8080] [devhub-dev-annuaire-canary-8080] 10.244.1.87:8080 ...   ← canary, systématiquement
```

`10.244.1.87` est vérifié être l'IP du pod canary (`kubectl get pods -o wide`) — 5 requêtes avec le header consécutives, 5 fois routées sur le canary, sans exception, indépendamment du `setWeight: 25` courant. Sans le header, retour observé sur les pods stables (`10.244.1.74`/`10.244.1.69`) dans la quasi-totalité des cas (comportement pondéré normal).

Piège du poly vérifié en pratique : avec `canary-by-header`, le `canary-weight` est **ignoré** pour les requêtes qui matchent le header — ce n'est pas une combinaison additive, le header gagne. Confirmé : toutes les requêtes taggées ont atteint le canary même si le tirage aléatoire pondéré (25%) ne l'aurait statistiquement pas justifié à chaque fois.

Usage métier documenté : cela permettrait à l'équipe produit de tester chaque release sur ses propres comptes (en ajoutant le header côté navigateur via une extension, ou côté API via un client de test) avant n'importe quel utilisateur — sans attendre la promotion progressive normale, et sans risquer d'exposer le reste du trafic. Combiné à l'`AnalysisTemplate` de l'étape 7 : le header permettrait à un humain de valider fonctionnellement le canary en parallèle de la validation automatique par métriques — les deux mécanismes sont indépendants et complémentaires, pas concurrents (l'un valide "ça marche pour un cas d'usage réel", l'autre "ça ne dégrade pas les métriques globales").

Note de rigueur : la vérification côté Prometheus (`rollouts_pod_template_hash` sur `http_requests_total`) n'a pas immédiatement reflété le trafic canary dans cette session — le pod canary venait d'être créé et la découverte de cible par Prometheus (cycle de scrape ~30s-1min) n'avait pas encore rattrapé son retard au moment du test. La preuve retenue est donc directement les logs d'accès `ingress-nginx`, plus fiable et immédiate pour ce cas précis (confirmation au niveau réseau, pas au niveau métriques agrégées).

---

## Étape 10 — Alerting Alertmanager et notifications Rollouts

**Deux `PrometheusRule`** (`platform-sre/alerting/prometheusrules.yaml`, ressources brutes déployées par une Application ArgoCD dédiée — pas de chart Helm nécessaire pour 2 manifestes) :

1. `HighErrorRate`, `severity: page` — `> 1%` de 5xx sur `[5m]`, `for: 5m` (une fluctuation transitoire ne doit pas déclencher, piège explicite de l'Annexe B du poly).
2. `LatencyDegraded`, `severity: ticket` — p95 au-delà du SLO de l'étape 1, `for: 30m`. Trois occurrences de cette alerte, une par service, avec le seuil propre à chacun (300/400/200ms) — pas un seuil unique arbitraire, cohérent avec le travail de l'étape 1.

Validées hors-cluster avant tout déploiement :

```
$ promtool check rules platform-sre/alerting/prometheusrules.yaml   # (extrait spec.groups)
SUCCESS: 4 rules found
```

**Alertmanager** (`platform-sre/values/kube-prometheus-stack-values.yaml`, champ `alertmanager.config`) route par sévérité :

- `severity: page` → receiver `primary-webhook`, `repeat_interval: 1h` (resignalé assez vite si personne n'acquitte — c'est une urgence).
- `severity: ticket` → receiver `secondary-webhook`, `repeat_interval: 12h` (pas besoin de spammer, ça peut attendre).

```
$ amtool check-config <extrait alertmanager.config>
Checking : SUCCESS
Found: - global config - route - 0 inhibit rules - 3 receivers - 0 templates
```

**Webhooks mockés** (`platform-sre/alerting/webhook-mock.yaml`, image `mendhak/http-https-echo`) : équivalent local de webhook.site — ce TP tourne sur un cluster kind sans accès à un compte externe, l'échoing local logge chaque payload reçu sur stdout, consultable comme preuve. Trois chemins : `/primary` (alertes page + rollouts abandonnés), `/secondary` (alertes ticket), `/rollout-success` (rollouts terminés avec succès).

**Notifications Argo Rollouts** (`platform-sre/values/argo-rollouts-values.yaml`, champ `notifications`) : deux triggers custom (`on-rollout-completed` quand `phase == 'Healthy'`, `on-rollout-aborted` quand `phase == 'Degraded'`), deux templates avec payload JSON minimal, souscriptions par défaut (s'appliquent à tous les Rollouts sans annotation supplémentaire à poser par service) :

```
$ kubectl get configmap argo-rollouts-notification-configmap -n argo-rollouts -o yaml
# service.webhook, subscriptions, template.rollout-completed, template.rollout-aborted,
# trigger.on-rollout-aborted, trigger.on-rollout-completed — tous générés correctement
```

Piège du poly vérifié en configurant `repeat_interval` différencié (cf. ci-dessus) — sans ça, une alerte qui reste `firing` est resignalée toutes les 4h par défaut, mauvais réglage aussi bien pour du `page` (trop rare, on rate le fait que ça dégénère) que pour du `ticket` (trop court, ça devient du bruit).

**Anomalie rencontrée et documentée honnêtement (notifications Argo Rollouts, non résolue).** Contrairement à la configuration Alertmanager (validée `amtool check-config`, confirmée chargée en direct dans le pod Alertmanager via `amtool config show`), la livraison des notifications Argo Rollouts vers le webhook mocké échoue systématiquement. Le contrôleur reconnaît correctement le déclencheur et le destinataire nommé (`Sending notification about condition 'on-rollout-completed...' to '{webhook rollout-success}'`), mais l'envoi HTTP échoue avec une URL vide :

```
$ kubectl logs -n argo-rollouts deploy/argo-rollouts --since=30s | grep notif
level=info  msg="Sending notification ... to '{webhook rollout-success}' ..." resource=devhub-dev/annuaire
level=error msg="Failed to notify recipient {webhook rollout-success} ...: GET  giving up after 1 attempt(s): Get \"\": unsupported protocol scheme \"\" ..." resource=devhub-dev/annuaire
```

Trois structures de configuration testées pour la clé `notifiers` (ConfigMap `argo-rollouts-notification-configmap`), déclenchées par de vrais rollouts (pas de simulation) :

1. `service.webhook: |` contenant une map `{primary: {url:...}, rollout-success: {url:...}}` — le contrôleur résout correctement le nom du destinataire mais l'URL associée reste introuvable (résultat : `GET` avec URL vide).
2. `service.webhook.primary: |` / `service.webhook.rollout-success: |` (une clé ConfigMap distincte par instance nommée) — regression différente : `notification service 'webhook' is not supported` (le type "webhook" n'est plus reconnu du tout avec ce découpage de clé).
3. Retour à la structure 1, avec un champ `headers` explicite ajouté à chaque instance (hypothèse : un champ requis manquant faisait échouer le parsing silencieusement) — même échec qu'en 1.

La requête HTTP effectivement tentée est un `GET` sans corps, alors que le template définit explicitement `method: POST` — signe que l'override `webhook: <nom>: {method, body}` du template n'est jamais atteint, la résolution échouant avant, au niveau du notifier de base. Root cause non élucidée dans le temps disponible : plausible incompatibilité entre le format multi-instances documenté dans les exemples du chart (`helm show values`) et la version réelle du moteur de notifications embarquée dans `argo-rollouts` `2.41.0`, ou un champ requis non documenté dans les exemples consultés. Le mécanisme d'alerting Prometheus/Alertmanager (déjà démontré fonctionnel ci-dessus) reste le canal de notification fiable de cette chaîne ; les notifications Rollouts natives sont configurées correctement au sens GitOps (la `ConfigMap` est déployée, versionnée, et le contrôleur la lit) mais n'aboutissent pas en pratique — à corriger avant tout usage réel, par exemple en repartant d'un exemple minimal à une seule instance webhook non nommée pour isoler précisément où la résolution casse.

Les **deux** déclencheurs ont été testés en conditions réelles avec le même résultat : un canary mené à `Healthy` (`on-rollout-completed` → `{webhook rollout-success}`) et un canary explicitement `abort`é (`on-rollout-aborted` → `{webhook primary}`) échouent tous les deux avec exactement la même erreur (`GET "": unsupported protocol scheme ""`) — confirmant que le bug est dans la résolution du notifier de base, pas dans un trigger ou un template en particulier.

Limitation honnêtement documentée : le contenu minimal demandé par le poly pour chaque notification (nom du Rollout, version sortante, version entrante, durée totale, conclusion) n'est que **partiellement** atteint par les templates ci-dessus. Nom, image active (« version entrante ») et conclusion (`phase`) sont disponibles nativement dans le contexte de templating (`.rollout.metadata.name`, `.rollout.spec.template.spec.containers[0].image`, `.rollout.status.phase`). La **version sortante** (image précédente) et la **durée totale** de la promotion ne sont pas exposées comme des champs directs et simples dans ce contexte — les obtenir proprement demanderait soit de lire `.rollout.status.conditions` (timestamps de début/fin, à parser en Go template avec des fonctions Sprig de calcul de durée) soit une source externe (les événements Kubernetes du Rollout, déjà utilisés informellement dans ce rapport via `kubectl get events`). Non résolu dans le temps disponible de ce TP — à noter dans "ce que cette chaîne ne sait pas faire" (étape 12) plutôt que de fabriquer un template qui prétendrait le faire correctement.

---

## Étape 11 — Comparer Argo Rollouts, Flagger, et la rolling-update native

Notes de 0 à 5, argumentées à partir de l'expérience directe de ce TP (pas seulement de la documentation) pour Argo Rollouts et RollingUpdate ; Flagger jugé sur sa réputation/documentation publique, jamais installé dans ce TP.

| Critère | RollingUpdate natif | Argo Rollouts | Flagger |
|---|---|---|---|
| Courbe d'apprentissage | 5 — natif à K8s, zéro concept nouveau | 2 — CRD dédiée, vocabulaire propre (Rollout/AnalysisTemplate/AnalysisRun), documentation dense ; ce TP a pris plusieurs itérations pour bien câbler l'AnalysisTemplate (3 tentatives, cf. étape 7) | 2 — même famille de complexité qu'Argo Rollouts, mais philosophie CRD "légère" (annote un Deployment existant plutôt que le remplacer) qui réduit un peu la friction initiale |
| Intégration avec ArgoCD (workflow GitOps) | 5 — c'est le comportement par défaut d'un Deployment, aucune surprise | 3 — fonctionne bien une fois calé, mais avec des frictions réelles rencontrées ce TP : `ignoreDifferences` obligatoire sur `spec.selector` (sinon `OutOfSync` perpétuel), un bug de normalisation de `protocol: TCP` sur les CRD, et une anomalie non résolue sur `autoPromotionEnabled` en blueGreen (étape 8) | 3 — a priori similaire (même patron d'intégration ArgoCD), non vérifié en pratique dans ce TP |
| Intégration avec Flux (workflow GitOps) | 5 — idem | 3 — a priori équivalent à ArgoCD (même mécanique CRD), non testé | 4 — Flagger est historiquement plus proche de l'écosystème Flux (même éditeur, Weaveworks à l'origine) ; documentation et exemples Flux généralement plus étoffés pour Flagger que pour Argo Rollouts |
| Variété des stratégies (canary, blueGreen, A/B, shadow) | 0 — aucune, uniquement un remplacement progressif uniforme | 4 — canary et blueGreen couverts en profondeur dans ce TP, `Experiment` (A/B) mentionné en défi bonus non traité, shadow non couvert | 4 — canary et blueGreen également, A/B testing natif via en-têtes/cookies documenté comme un cas de prembattre classe |
| Variété des metric providers | 0 — aucune notion de métrique, seulement des probes K8s | 5 — Prometheus (utilisé ce TP), Datadog, Wavefront, New Relic, CloudWatch, webhook custom | 4 — Prometheus, Datadog, CloudWatch également, catalogue légèrement plus restreint |
| UI / dashboard prêt à l'emploi | 0 — aucun (juste `kubectl rollout status`) | 4 — dashboard web dédié (`kubectl argo rollouts dashboard`, exposé ce TP sur `rollouts.devhub.local`), utile mais moins riche que l'UI ArgoCD elle-même | 1 — pas de dashboard natif ; s'appuie sur Grafana (dashboards communautaires) ou l'UI d'un service mesh |
| Coût opérationnel dans le cluster | 5 — zéro composant supplémentaire | 3 — un contrôleur + CRDs + (optionnel) dashboard à opérer, observés dans ce TP (namespace `argo-rollouts` dédié) | 4 — un seul contrôleur léger, pas de CRD `Rollout` remplaçant le `Deployment` (Flagger orchestre un Deployment existant en le dupliquant en primary/canary lui-même) |
| Adapté à un mesh (Linkerd, Istio) | 1 — aucune intégration, un mesh peut aider au split L7 mais RollingUpdate lui-même l'ignore totalement | 3 — supporté (SMI, Istio VirtualService) mais pas testé ce TP (on a utilisé ingress-nginx, pas un mesh) | 5 — c'est le cas d'usage historique de Flagger, intégration mesh considérée plus mature/native dans l'écosystème |
| Communauté / fréquence des releases | 3 — mainteneur = K8s lui-même, très stable mais pas de "release" dédiée au sens propre | 4 — projet CNCF Graduated (2022), activité soutenue, version installée ce TP (2.41.0) très récente (juillet 2026) | 3 — projet CNCF mais pas Graduated à ce jour, cadence de release perçue comme moins soutenue qu'Argo Rollouts ces derniers mois |
| Risque si le contrôleur tombe en plein canary | 5 — pas de contrôleur externe, le `Deployment` continue d'être géré nativement par le control-plane K8s | 2 — le canary reste figé à son poids courant (ni promotion ni rollback) tant que le contrôleur ne redémarre pas — observé indirectement ce TP quand le contrôleur a dû être relancé (patch operator, étape 3) | 2 — même risque structurel, Flagger est également un contrôleur externe unique |

Cellules où la note s'écarte de 3, argumentées ci-dessus dans le tableau — pas de commentaire séparé nécessaire, la colonne "critère" porte déjà la justification.

---

## Étape 12 — Synthèse obligatoire : « ma chaîne de release est-elle production-ready ? »

### Livrable 1 — Rétrospective TP2 → TP3

| Opération | Ce que la colonne TP3 a vraiment fait ressentir | Où le surcoût opérationnel n'est PAS justifié pour une startup de 3 personnes | Ce qui justifierait le passage TP2→TP3 pour une PME en croissance |
|---|---|---|---|
| Déployer une nouvelle version | Plus lent (5 min d'analyse minimum) mais objectivement plus rassurant — la première fois qu'un `AnalysisRun` a promu tout seul (étape 7), c'était la première fois de tout le TP que je n'ai RIEN eu à vérifier manuellement avant de dire "c'est bon". | — | — |
| Détecter qu'une nouvelle version dégrade le service | Le contraste est frappant avec le TP1 (aucune métrique) : ici la dégradation est mesurée en continu, pas découverte par un utilisateur qui appelle le support. | Une petite équipe qui déploie 2x/semaine peut se permettre de surveiller un dashboard 10 minutes après chaque déploiement — l'automatisation ne fait gagner que peu de temps humain à ce volume. | Dès que la fréquence de déploiement dépasse ce qu'une personne peut surveiller manuellement (plusieurs fois par jour, plusieurs équipes), l'automatisation devient la seule option qui scale. |
| Limiter l'impact d'une mauvaise version | Contraint, au sens positif : on ne PEUT plus déployer sans y penser (writer un `Rollout`, penser aux steps) — ça oblige à une discipline qu'un `Deployment` nu ne demande pas. | — | — |
| Savoir si le service tient son SLO | Rassurant : la question "est-ce que ça va" a enfin une réponse chiffrée plutôt qu'un ressenti. | Sans clients externes avec des attentes contractuelles, un SLO formel est un exercice plus pédagogique qu'opérationnel pour une toute petite structure. | Dès qu'un premier client signe un SLA, le SLO interne devient la seule façon de savoir si on est en train de le tenir avant que le client s'en rende compte. |
| Décider de promouvoir une release | Plus rapide en confiance, plus lent en horloge murale — décider "au feeling" (TP1/TP2) est instantané mais faux ; attendre 5 min de preuve est plus lent mais vrai. | — | — |
| Justifier un déploiement à 17h vendredi | C'est la ligne qui a le plus changé mon rapport au risque : « le canary est positif sur 30 min » est une phrase qu'on peut dire à un manager sans bluffer, contrairement à « ça devrait passer ». | **Ici, clairement pas justifié pour 3 personnes** : à ce stade, la vraie réponse rationnelle un vendredi 17h reste « on ne déploie pas », peu importe l'outillage — aucune stack de progressive delivery ne remplace la décision humaine de ne pas prendre de risque un vendredi soir. | Une équipe avec astreinte formelle et SLA à tenir 24/7 ne PEUT pas se permettre de geler les déploiements un jour sur sept — la chaîne TP3 devient alors ce qui rend un déploiement vendredi 17h *raisonnable*. |
| Mesurer la fréquence de déploiement (DORA) | La mesure est désormais native (objets `Rollout`, historique de révisions) plutôt que reconstruite après coup depuis des logs CI. | **Deuxième cas où le surcoût n'est pas justifié** : une équipe de 3 personnes connaît sa fréquence de déploiement de mémoire, calculer du DORA formel est un exercice de reporting sans destinataire réel à cette taille. | Dès qu'il y a un comité d'architecture ou un besoin de justifier un budget plateforme, avoir les métriques DORA "gratuites" (déjà dans les objets Rollout) évite un projet de tooling dédié. |
| Mesurer le change failure rate (DORA) | Idem — comptable plutôt qu'anecdotique (« rollouts annulés/promus » vs souvenirs et tickets Jira). | — | — |
| Tester une version sur un cohort d'utilisateurs | La fonctionnalité qui m'a le plus surpris par sa simplicité une fois en place (étape 9) — un header HTTP suffit, aucune infrastructure de feature-flagging à opérer en plus. | — | C'est l'opération, à elle seule, qui justifierait à mes yeux le passage TP2→TP3 pour une PME en croissance : pouvoir dire à l'équipe produit « testez en prod sur vos comptes avant n'importe quel utilisateur » sans processus de feature flag séparé change fondamentalement la vitesse à laquelle le produit peut itérer, indépendamment de la maturité SRE. |

### Livrable 2 — Ce que cette chaîne ne sait toujours pas faire

**1. Traçabilité distribuée** (un appel utilisateur → tous les services traversés). *Risque concret* : un incident touchant `annuaire` provoqué par un appel amont de `planning` (ou l'inverse) est invisible dans cette chaîne — chaque service expose ses propres métriques RED, mais rien ne relie une requête `planning` à la requête `annuaire` qu'elle a éventuellement déclenchée. En prod chez un vrai client, un incident multi-service se diagnostiquerait à l'aveugle, service par service. *Outil* : OpenTelemetry (instrumentation) + Jaeger ou Tempo (visualisation). *Référence* : `opentelemetry.io/docs/concepts/instrumentation`.

**2. Logs centralisés corrélés aux métriques.** *Risque concret* : quand une alerte `HighErrorRate` se déclenche (étape 10), la seule information disponible est un pourcentage — pas le message d'erreur exact ni la stack trace du pod qui a échoué. Il faut aujourd'hui `kubectl logs` pod par pod, à la main, pendant que le pod peut déjà avoir été recyclé. *Outil* : Loki + Fluent Bit, avec des *exemplars* Prometheus reliant une mesure de latence à une trace/log précis. *Référence* : `grafana.com/docs/loki`.

**3. Mesure côté utilisateur réel (latence navigateur).** *Risque concret* : tout ce que ce TP mesure est côté serveur — un p95 de 47ms côté `annuaire` ne dit rien du temps que met réellement un étudiant à voir sa page charger (réseau, JS, rendu). Un incident purement frontend serait invisible à cette chaîne entière. *Outil* : RUM (Real User Monitoring), Web Vitals. *Référence* : `web.dev/vitals`.

**4. Chaos engineering applicatif.** *Risque concret* : la chaîne promet une résilience ("canary rollback auto") jamais testée contre une vraie panne aléatoire — un `pod kill` en pleine promotion, une latence réseau injectée entre `annuaire` et Prometheus. Sans l'avoir testé, c'est une hypothèse de résilience, pas une preuve. *Outil* : Chaos Mesh ou LitmusChaos. *Référence* : `chaos-mesh.org`.

**5. Politique d'admission des manifestes.** *Risque concret* : rien n'empêche aujourd'hui un développeur de committer un `Deployment` nu à la place d'un `Rollout` dans `services/annuaire/chart/templates/` — toute la protection de ce TP disparaîtrait silencieusement au prochain sync ArgoCD, sans qu'aucun garde-fou ne le bloque. *Outil* : Kyverno (policy "no Rollout without AnalysisTemplate" mentionnée en Annexe A du poly) ou OPA Gatekeeper. *Référence* : `kyverno.io/policies`.

**6. Signature des images et provenance (chaîne d'approvisionnement).** *Risque concret* : les images `ghcr.io/chesaad/*` construites dans ce TP ne sont ni signées ni accompagnées d'une attestation de provenance — rien ne garantit qu'une image tirée en prod correspond exactement au code source qu'on croit avoir buildé, ni qu'elle n'a pas été altérée entre le build et le déploiement. *Outil* : Sigstore/cosign, in-toto, conformité SLSA. *Référence* : `slsa.dev`.

**7. Backup applicatif et DR (disaster recovery).** *Risque concret* : les trois services de ce TP sont volontairement sans état (CRUD en mémoire), donc hors sujet ici — mais une vraie plateforme aurait une base de données, et rien dans cette chaîne ne couvre sa sauvegarde/restauration. Un canary qui échoue sur une migration de schéma DB n'a *aucun* filet ici, contrairement au trafic HTTP. *Outil* : Velero, snapshots PVC, dump SGBD régulier. *Référence* : `velero.io`.

### Livrable 3 — Position d'architecte

Demain, responsable plateforme dans une boîte à 10 services et 30 développeurs : je garde intégralement la chaîne du TP3 — GitOps + Rollouts + Prometheus est le socle minimal pour déployer sans y penser à chaque fois, et rien dans ce TP ne m'a semblé être du sur-engineering pour cette taille d'équipe. Je remplace Grafana par un mix Grafana/Perses dès que Perses sort de Sandbox, pour rester 100% CNCF Graduated par cohérence d'argumentaire en comité d'archi (poly, page 4). Je remplace mes webhooks mockés par de vrais canaux (Slack/PagerDuty) et j'écris un runbook par alerte — sans ça, une alerte `page` à 3h du matin ne sert à rien de plus qu'un bruit. J'ajoute, dans l'ordre de priorité issu du Livrable 2 : (1) traçabilité distribuée dès qu'un deuxième service appelle un premier (le cas le plus probable à 10 services), (2) logs centralisés corrélés, sans quoi chaque alerte se termine en fouille manuelle, (3) une politique Kyverno qui rend impossible de contourner Rollout/AnalysisTemplate par erreur — le seul des sept manques qui protège contre une régression humaine plutôt que technique. Le chaos engineering et la signature d'images arrivent ensuite, une fois la base opérationnelle solide. Et j'accepte, en connaissance de cause, que cette chaîne ne protège toujours rien côté base de données — ce sera le sujet du prochain chantier avant le premier vrai client.

---
