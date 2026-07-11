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
