SHELL := /bin/bash
CLUSTER ?= pulse
ARGOCD_CHART_VERSION ?= 7.6.12
INGRESS_CHART_VERSION ?= 4.11.3

SERVICES := annuaire planning notif
SHA := $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
# Adaptez GHCR_USER à votre compte GitHub.
GHCR_USER ?= changeme

.PHONY: help tools-check cluster-up cluster-down argocd-install argocd-password \
        hosts-print helm-lint images-build images-load clean

help:
	@echo "Cibles disponibles :"
	@echo "  tools-check       - vérifie les CLI requises (TP 2 + TP 3)"
	@echo "  cluster-up        - démarre un cluster kind 2 nœuds"
	@echo "  cluster-down      - détruit le cluster"
	@echo "  argocd-install    - installe ingress-nginx + ArgoCD (Helm)"
	@echo "  argocd-password   - affiche le mot de passe admin initial d'ArgoCD"
	@echo "  hosts-print       - lignes à ajouter dans /etc/hosts"
	@echo "  helm-lint         - helm lint sur les charts des trois services"
	@echo "  images-build      - build des trois images applicatives (tag SHA)"
	@echo "  images-load       - kind load des trois images dans le cluster"
	@echo "  clean             - détruit le cluster et nettoie les artefacts locaux"

tools-check:
	@missing=0; \
	for t in docker kubectl helm kind argocd promtool; do \
		if ! command -v $$t >/dev/null 2>&1; then echo "manquant : $$t"; missing=1; fi; \
	done; \
	if ! kubectl argo rollouts version >/dev/null 2>&1; then \
		echo "manquant : plugin kubectl-argo-rollouts (kubectl argo rollouts)"; missing=1; \
	fi; \
	if [ $$missing -ne 0 ]; then exit 1; fi
	@echo "tous les outils sont présents."
	@docker version --format '  docker  : {{.Server.Version}}' 2>/dev/null || true
	@kubectl version --client 2>/dev/null | head -n1 | sed 's/^/  kubectl : /'
	@helm version --short | sed 's/^/  helm    : /'
	@kind version | sed 's/^/  /'
	@argocd version --client --short 2>/dev/null | sed 's/^/  /'
	@kubectl argo rollouts version 2>/dev/null | head -n1 | sed 's/^/  rollouts: /'
	@promtool --version 2>&1 | head -n1 | sed 's/^/  /'

cluster-up:
	kind create cluster --name $(CLUSTER) --config cluster/kind-config.yaml
	@echo ">>> cluster prêt — contexte courant : kind-$(CLUSTER)"

cluster-down:
	kind delete cluster --name $(CLUSTER)

argocd-install:
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	helm repo update
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
		--namespace ingress-nginx --create-namespace \
		--version $(INGRESS_CHART_VERSION) \
		--set controller.service.type=NodePort \
		--set-string controller.nodeSelector."ingress-ready"=true \
		--set "controller.tolerations[0].key=node-role.kubernetes.io/control-plane" \
		--set "controller.tolerations[0].operator=Exists" \
		--set "controller.tolerations[0].effect=NoSchedule" \
		--set controller.hostPort.enabled=true \
		--set controller.publishService.enabled=false
	kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=180s
	helm upgrade --install argocd argo/argo-cd \
		--namespace argocd --create-namespace \
		--version $(ARGOCD_CHART_VERSION)

argocd-password:
	@kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d ; echo

hosts-print:
	@echo "ajoutez ces lignes à votre fichier hosts :"
	@echo "  macOS/Linux : /etc/hosts"
	@echo "  Windows     : C:\\Windows\\System32\\drivers\\etc\\hosts"
	@echo ""
	@echo "127.0.0.1  argocd.devhub.local"
	@echo "127.0.0.1  grafana.devhub.local"
	@echo "127.0.0.1  prometheus.devhub.local"
	@echo "127.0.0.1  rollouts.devhub.local"
	@echo "127.0.0.1  annuaire.devhub.local"
	@echo "127.0.0.1  planning.devhub.local"
	@echo "127.0.0.1  notif.devhub.local"

helm-lint:
	@for svc in $(SERVICES); do \
		echo ">>> helm lint $$svc"; \
		helm lint services/$$svc/chart || exit 1; \
	done

images-build:
	@for svc in $(SERVICES); do \
		echo ">>> docker build $$svc:$(SHA)"; \
		docker build -t ghcr.io/$(GHCR_USER)/$$svc:$(SHA) services/$$svc; \
	done

images-load:
	@for svc in $(SERVICES); do \
		echo ">>> kind load ghcr.io/$(GHCR_USER)/$$svc:$(SHA)"; \
		kind load docker-image ghcr.io/$(GHCR_USER)/$$svc:$(SHA) --name $(CLUSTER); \
	done

clean:
	kind delete cluster --name $(CLUSTER) 2>/dev/null || true
