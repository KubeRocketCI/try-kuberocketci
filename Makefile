# KubeRocketCI local test harness — kind + KubeRocketCI on Docker Desktop (macOS).
# Run `make help` for the workflow. Typical first run:  make up
SHELL := /bin/bash
.ONESHELL:
.DEFAULT_GOAL := help

# ---- config -----------------------------------------------------------------
CLUSTER            ?= krci
CTX                ?= kind-$(CLUSTER)
NS                 ?= krci
WILDCARD           ?= 127.0.0.1.nip.io
EDP_VERSION        ?= 3.13.5
HELM_REPO_NAME     ?= epamedp
HELM_REPO_URL      ?= https://epam.github.io/edp-helm-charts/stable
INGRESS_NGINX_REF  ?= controller-v1.11.3
CERT_MANAGER_VER   ?= v1.16.2
CERT_MANAGER_MANIFEST ?= https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VER)/cert-manager.yaml
ARGOCD_MANIFEST    ?= https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# Versions pinned to what KubeRocketCI docs specify for edp-tekton compatibility.
TEKTON_PIPELINE    ?= https://storage.googleapis.com/tekton-releases/pipeline/previous/v1.6.0/release.yaml
TEKTON_TRIGGERS    ?= https://storage.googleapis.com/tekton-releases/triggers/previous/v0.34.0/release.yaml
TEKTON_INTERCEPT   ?= https://storage.googleapis.com/tekton-releases/triggers/previous/v0.34.0/interceptors.yaml
# Tekton Results — canonical KRCI manifest (v0.17.2) copied verbatim from
# edp-cluster-add-ons (clusters/core/addons/tekton/results.yaml). Self-contained:
# api-config ConfigMap baked in, TLS disabled. Backed by minimal Postgres
# (manifests/tekton-results-postgres.yaml) that fulfils the manifest's DB contract.
TEKTON_RESULTS_MANIFEST ?= manifests/tekton-results.yaml
TEKTON_NS          ?= tekton-pipelines
# Prometheus (kube-prometheus-stack) — versions from edp-cluster-add-ons prometheus-operator addon.
PROM_REPO_NAME     ?= prometheus-community
PROM_REPO_URL      ?= https://prometheus-community.github.io/helm-charts
PROM_CHART_VERSION ?= 84.5.0
MONITORING_NS      ?= monitoring
VALUES             ?= values/edp-install.yaml
KUBECTL            := kubectl --context $(CTX)

# ---- meta -------------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Quick start:  make preflight && make testbed && make token"

.PHONY: preflight
preflight: ## Check docker RAM + required tools
	@set -e
	for t in kind helm kubectl docker; do command -v $$t >/dev/null || { echo "missing required tool: $$t"; exit 1; }; done
	mem=$$(docker info --format '{{.MemTotal}}' 2>/dev/null || true)
	if [ -z "$${mem:-}" ] || ! [ "$${mem}" -gt 0 ] 2>/dev/null; then \
	  echo "   (warn) could not read Docker memory (is Docker running?); skipping RAM check"; \
	else \
	  gib=$$(( mem / 1024 / 1024 / 1024 )); \
	  echo "Docker MemTotal: $${gib} GiB"; \
	  if [ "$${gib}" -lt 6 ]; then \
	    echo "!! Docker has only $${gib} GiB. Give it >=8GB (Docker Desktop > Settings > Resources)."; \
	    exit 1; \
	  elif [ "$${gib}" -lt 8 ]; then \
	    echo "   (warn) <8GB; core may be tight. GitLab phase needs ~12GB."; \
	  else \
	    echo "   RAM OK for core stack (GitLab phase needs ~12GB)."; \
	  fi; \
	fi
	echo "preflight OK"

# ---- tooling ----------------------------------------------------------------
.PHONY: tools
tools: ## brew install kind
	brew install kind

# ---- cluster ----------------------------------------------------------------
.PHONY: cluster
cluster: ## Create the kind cluster (ports 80/443 -> localhost)
	@if kind get clusters 2>/dev/null | grep -qx $(CLUSTER); then \
	  echo "cluster '$(CLUSTER)' already exists"; \
	else \
	  kind create cluster --config kind/cluster.yaml; \
	fi
	$(KUBECTL) cluster-info

.PHONY: ingress
ingress: ## Install ingress-nginx (kind provider) and wait
	$(KUBECTL) apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/$(INGRESS_NGINX_REF)/deploy/static/provider/kind/deploy.yaml
	$(KUBECTL) -n ingress-nginx wait --for=condition=Available deploy/ingress-nginx-controller --timeout=300s

.PHONY: cert-manager
cert-manager: ## Install cert-manager (required by KubeRocketCI operator webhooks)
	$(KUBECTL) apply -f $(CERT_MANAGER_MANIFEST)
	$(KUBECTL) -n cert-manager rollout status deploy/cert-manager --timeout=300s
	$(KUBECTL) -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
	$(KUBECTL) -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=300s

.PHONY: tekton
tekton: ## Install Tekton Pipelines + Triggers + interceptors
	$(KUBECTL) apply -f $(TEKTON_PIPELINE)
	$(KUBECTL) apply -f $(TEKTON_TRIGGERS)
	$(KUBECTL) apply -f $(TEKTON_INTERCEPT)
	$(KUBECTL) -n tekton-pipelines rollout status deploy/tekton-pipelines-controller --timeout=300s
	$(KUBECTL) -n tekton-pipelines rollout status deploy/tekton-triggers-controller --timeout=300s
	# The admission webhook MUST be serving before KubeRocketCI applies its
	# Pipeline CRs, otherwise helm install fails with "connection refused" on
	# webhook.pipeline.tekton.dev (server-side apply race).
	$(KUBECTL) -n tekton-pipelines rollout status deploy/tekton-pipelines-webhook --timeout=300s
	$(KUBECTL) -n tekton-pipelines wait --for=condition=Available \
	  deploy/tekton-pipelines-webhook deploy/tekton-triggers-webhook --timeout=300s

.PHONY: argocd
argocd: ## (optional) Install Argo CD for CD/deploy stages
	$(KUBECTL) get ns argocd >/dev/null 2>&1 || $(KUBECTL) create ns argocd
	$(KUBECTL) -n argocd apply -f $(ARGOCD_MANIFEST)
	$(KUBECTL) -n argocd rollout status deploy/argocd-server --timeout=300s

# ---- KubeRocketCI -----------------------------------------------------------
.PHONY: repo
repo: ## Add/update the KubeRocketCI helm repo
	helm repo add $(HELM_REPO_NAME) $(HELM_REPO_URL) 2>/dev/null || true
	helm repo update $(HELM_REPO_NAME)

.PHONY: krci-dry-run
krci-dry-run: repo ## Render the chart (no install) to reveal required values
	helm upgrade --install edp $(HELM_REPO_NAME)/edp-install \
	  --version $(EDP_VERSION) -n $(NS) --create-namespace \
	  -f $(VALUES) --dry-run --debug 2>&1 | tail -60

.PHONY: krci
krci: repo ## Install KubeRocketCI (edp-install $(EDP_VERSION))
	helm upgrade --install edp $(HELM_REPO_NAME)/edp-install \
	  --version $(EDP_VERSION) -n $(NS) --create-namespace \
	  -f $(VALUES) --wait --timeout 900s
	$(KUBECTL) -n $(NS) get pods

# ---- platform capabilities --------------------------------------------------
.PHONY: prometheus
prometheus: ## Install kube-prometheus-stack ($(PROM_CHART_VERSION)) + Grafana
	helm repo add $(PROM_REPO_NAME) $(PROM_REPO_URL) 2>/dev/null || true
	helm repo update $(PROM_REPO_NAME)
	helm upgrade --install prometheus $(PROM_REPO_NAME)/kube-prometheus-stack \
	  --version $(PROM_CHART_VERSION) -n $(MONITORING_NS) --create-namespace \
	  -f values/kube-prometheus-stack.yaml --wait --timeout 600s
	$(KUBECTL) -n $(MONITORING_NS) get pods

.PHONY: tekton-results
tekton-results: ## Install Tekton Results (v0.17.2, KRCI manifest) + minimal Postgres
	# 1) minimal Postgres + DB secret (fulfils the manifest's results-primary /
	# results-pguser-results contract), then 2) the canonical KRCI Results manifest.
	# The api ConfigMap is baked into the manifest and TLS is disabled, so no
	# separate config/cert step is needed — Postgres just has to exist first.
	$(KUBECTL) apply -f manifests/tekton-results-postgres.yaml
	$(KUBECTL) -n $(TEKTON_NS) rollout status deploy/results-primary --timeout=300s
	$(KUBECTL) apply -f $(TEKTON_RESULTS_MANIFEST)
	$(KUBECTL) -n $(TEKTON_NS) rollout status deploy/tekton-results-api --timeout=300s
	$(KUBECTL) -n $(TEKTON_NS) rollout status deploy/tekton-results-watcher --timeout=300s
	# Ingress so the Portal can read Results at a stable nip.io URL (no port-forward).
	$(KUBECTL) apply -f manifests/tekton-results-ingress.yaml
	$(KUBECTL) -n $(TEKTON_NS) get pods | grep -E 'results|NAME'
	@echo "Tekton Results API: http://tekton-results.$(WILDCARD)  (set TEKTON_RESULTS_URL to this)"

# ---- access -----------------------------------------------------------------
.PHONY: token
token: ## Mint a 24h cluster-admin token for Portal login (local only)
	@$(KUBECTL) -n $(NS) get sa krci-admin >/dev/null 2>&1 || $(KUBECTL) -n $(NS) create sa krci-admin
	$(KUBECTL) get clusterrolebinding krci-admin >/dev/null 2>&1 || \
	  $(KUBECTL) create clusterrolebinding krci-admin --clusterrole=cluster-admin --serviceaccount=$(NS):krci-admin
	@echo "----- BEARER TOKEN (paste into the Portal 'Sign In with Token' dialog) -----"
	@$(KUBECTL) -n $(NS) create token krci-admin --duration=24h

.PHONY: results-forward
results-forward: ## Port-forward the Tekton Results API to localhost:8080
	@echo "Tekton Results API -> http://localhost:8080  (Ctrl-C to stop)"
	$(KUBECTL) -n $(TEKTON_NS) port-forward svc/tekton-results-api-service 8080:8080

.PHONY: status
status: ## Show cluster + KubeRocketCI status
	@$(KUBECTL) get nodes
	@echo "--- krci pods ---"; $(KUBECTL) -n $(NS) get pods
	@echo "--- ingresses ---"; $(KUBECTL) -n $(NS) get ingress
	@echo "--- monitoring ---"; $(KUBECTL) -n $(MONITORING_NS) get pods 2>/dev/null || echo "(not installed)"
	@echo "--- tekton-results ---"; $(KUBECTL) -n $(TEKTON_NS) get pods 2>/dev/null | grep -E 'results' || echo "(not installed)"
	@$(KUBECTL) -n $(TEKTON_NS) get ingress tekton-results-api >/dev/null 2>&1 && echo "    Results API: http://tekton-results.$(WILDCARD)" || true

# ---- self-hosted git --------------------------------------------------------
.PHONY: gitlab
gitlab: ## Deploy self-hosted GitLab + GitServer + webhook wiring
	bash scripts/gitlab.sh

.PHONY: e2e
e2e: ## Validate end-to-end: trigger a review pipeline; PASS = green except sonar
	bash scripts/e2e-review.sh

.PHONY: gitlab-status
gitlab-status: ## Show GitLab + GitServer + EventListener + webhook state
	@echo "--- gitlab pod ---";    $(KUBECTL) -n gitlab get pods 2>/dev/null || echo "(not installed)"
	@echo "--- gitserver ---";     $(KUBECTL) -n $(NS) get gitserver gitlab -o jsonpath='{.status}' 2>/dev/null; echo
	@echo "--- eventlistener ---"; $(KUBECTL) -n $(NS) get eventlistener edp-gitlab 2>/dev/null || echo "(none yet)"
	@echo "--- el ingress ---";    $(KUBECTL) -n $(NS) get ingress event-listener-gitlab 2>/dev/null || echo "(none yet)"
	@echo "--- coredns rewrites ---"; $(KUBECTL) -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep 'rewrite name' || true
	@echo "--- pipelineruns ---";  $(KUBECTL) -n $(NS) get pipelinerun 2>/dev/null | tail -8 || echo "(none)"

# ---- lifecycle --------------------------------------------------------------
.PHONY: up
up: preflight cluster ingress cert-manager tekton krci ## Bring up the core stack (no Argo/GitLab)
	@echo "Core stack up. Next:  make testbed  (adds Prometheus + Tekton Results), then make token"

.PHONY: testbed
testbed: up prometheus tekton-results ## Full test bed: core stack + Prometheus + Tekton Results
	@echo "Full test bed up. Capabilities: Prometheus ($(PROM_CHART_VERSION)), Tekton Results (v0.17.2)."

.PHONY: down
down: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)
