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
# Argo CD (KRCI CD engine) — community chart. Latest 9.5.17 (appVersion v3.4.3);
# edp-cluster-add-ons pins 9.5.13/v3.4.1. Single-instance values in values/argo-cd.yaml.
ARGOCD_REPO_NAME   ?= argo
ARGOCD_REPO_URL    ?= https://argoproj.github.io/argo-helm
ARGOCD_CHART_VERSION ?= 9.5.17
ARGOCD_NS          ?= argocd
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
# SonarQube (KRCI code-quality engine) — chart from SonarSource; version pinned to what
# edp-cluster-add-ons ships. Backed by our own minimal Postgres (like Tekton Results).
# The KRCI sonar-operator (epamedp) + its CRs add the quality gate / ci-user.
SONAR_REPO_NAME    ?= sonarqube
SONAR_REPO_URL     ?= https://SonarSource.github.io/helm-chart-sonarqube
SONAR_CHART_VERSION ?= 2025.3.1
SONAR_OPERATOR_VERSION ?= 3.3.0
SONAR_NS           ?= sonar
# Predictable LOCAL-ONLY GitLab root password (seeded on first install). Override to taste.
# NB: GitLab 17.x rejects passwords containing the app name ("gitlab") or the username
# ("root") as "commonly used", so keep this clear of those words.
GITLAB_ROOT_PASSWORD ?= KrciLocal_2026!
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
argocd: ## Install Argo CD (chart $(ARGOCD_CHART_VERSION), single instance) + krci AppProject
	helm repo add $(ARGOCD_REPO_NAME) $(ARGOCD_REPO_URL) 2>/dev/null || true
	helm repo update $(ARGOCD_REPO_NAME)
	helm upgrade --install argocd $(ARGOCD_REPO_NAME)/argo-cd \
	  --version $(ARGOCD_CHART_VERSION) -n $(ARGOCD_NS) --create-namespace \
	  -f values/argo-cd.yaml --wait --timeout 600s
	# AppProject can't be expressed in chart values; apply it here (argocd ns, self-contained).
	$(KUBECTL) apply -f manifests/argocd-appproject-krci.yaml
	# apps-in-any-namespace needs the appset controller to read applications/appprojects
	# cluster-wide (the chart doesn't grant it) — see edp-cluster-add-ons rbac-hack.
	$(KUBECTL) apply -f manifests/argocd-appset-rbac.yaml
	$(KUBECTL) -n $(ARGOCD_NS) get pods
	@echo "Argo CD UI: http://argocd.$(WILDCARD)   (user admin; 'make argocd-password')"

.PHONY: argocd-integrate
argocd-integrate: ## (post-krci) Register the GitLab repo creds + create the ci-argocd secret in ns krci
	ARGOCD_REPO_NAME='$(ARGOCD_REPO_NAME)' ARGOCD_REPO_URL='$(ARGOCD_REPO_URL)' \
	  ARGOCD_CHART_VERSION='$(ARGOCD_CHART_VERSION)' ARGOCD_NS='$(ARGOCD_NS)' \
	  bash scripts/argocd-integrate.sh

.PHONY: argocd-password
argocd-password: ## Print the Argo CD initial admin password
	@$(KUBECTL) -n $(ARGOCD_NS) get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d; echo

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
krci: repo ## Install KubeRocketCI (edp-install $(EDP_VERSION)); renders GitServer/EL from values (run gitlab-up first)
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

.PHONY: sonar
sonar: repo ## Install SonarQube (chart $(SONAR_CHART_VERSION)) + own Postgres + sonar-operator + CRs
	# 1) our own minimal Postgres (fulfils the add-ons sonar-primary / sonar-pguser-sonar
	# contract), then 2) SonarQube (external jdbc -> that Postgres), then 3) the KRCI
	# sonar-operator + its CRs (Sonar/Group/PermissionTemplate/QualityGate/User).
	$(KUBECTL) apply -f manifests/sonar-postgres.yaml
	$(KUBECTL) -n $(SONAR_NS) rollout status deploy/sonar-primary --timeout=300s
	# Admin secret BEFORE the chart install: the post-install hook reads it to change the
	# default admin password on first startup (no manual first-login change), and the
	# sonar-operator authenticates with the same secret.
	$(KUBECTL) apply -f manifests/sonar-admin-secret.yaml
	helm repo add $(SONAR_REPO_NAME) $(SONAR_REPO_URL) 2>/dev/null || true
	helm repo update $(SONAR_REPO_NAME)
	helm upgrade --install sonar $(SONAR_REPO_NAME)/sonarqube \
	  --version $(SONAR_CHART_VERSION) -n $(SONAR_NS) --create-namespace \
	  -f values/sonarqube.yaml --wait --timeout 900s
	helm upgrade --install sonar-operator $(HELM_REPO_NAME)/sonar-operator \
	  --version $(SONAR_OPERATOR_VERSION) -n $(SONAR_NS) --wait --timeout 300s
	$(KUBECTL) apply -f manifests/sonar-operator-crs.yaml
	$(KUBECTL) -n $(SONAR_NS) get pods
	@echo "SonarQube UI: http://sonar.$(WILDCARD)  (user admin; 'make sonar-password')"

.PHONY: sonar-integrate
sonar-integrate: ## (post-krci) Mint a token + create the ci-sonarqube secret in ns krci
	bash scripts/sonar-integrate.sh

.PHONY: sonar-password
sonar-password: ## Print the SonarQube admin credentials (local default)
	@$(KUBECTL) -n $(SONAR_NS) get secret sonar-admin-password \
	  -o jsonpath='{.data.user}' | base64 -d; echo -n " / "; \
	  $(KUBECTL) -n $(SONAR_NS) get secret sonar-admin-password -o jsonpath='{.data.password}' | base64 -d; echo

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
status: ## Show cluster + KubeRocketCI status (tool URLs grouped at the bottom)
	@$(KUBECTL) get nodes
	@echo "--- krci pods ---"; $(KUBECTL) -n $(NS) get pods
	@echo "--- ingresses ---"; $(KUBECTL) -n $(NS) get ingress
	@echo "--- monitoring ---"; $(KUBECTL) -n $(MONITORING_NS) get pods 2>/dev/null || echo "(not installed)"
	@echo "--- argocd ---"; $(KUBECTL) -n $(ARGOCD_NS) get pods 2>/dev/null || echo "(not installed)"
	@echo "--- sonar ---"; $(KUBECTL) -n $(SONAR_NS) get pods 2>/dev/null || echo "(not installed)"
	@$(KUBECTL) -n $(NS) get secret ci-sonarqube >/dev/null 2>&1 && echo "    KRCI integration: secret/ci-sonarqube present (ns $(NS))" || echo "    KRCI integration: ci-sonarqube MISSING (run make sonar-integrate)"
	@echo "--- gitlab ---"; $(KUBECTL) -n gitlab get pods 2>/dev/null | grep -E 'gitlab|NAME' || echo "(not installed)"
	@echo "--- tekton-results ---"; $(KUBECTL) -n $(TEKTON_NS) get pods 2>/dev/null | grep -E 'results' || echo "(not installed)"
	@echo ""
	@echo "================ Tool URLs & credentials (local only) ================"
	@$(KUBECTL) -n $(ARGOCD_NS) get ingress argocd-server >/dev/null 2>&1 && { echo -n "  Argo CD UI:     http://argocd.$(WILDCARD)  (user admin / "; $(KUBECTL) -n $(ARGOCD_NS) get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo ")"; } || true
	@$(KUBECTL) -n $(SONAR_NS) get ingress sonar >/dev/null 2>&1 && { echo -n "  SonarQube UI:   http://sonar.$(WILDCARD)  (user admin / "; $(KUBECTL) -n $(SONAR_NS) get secret sonar-admin-password -o jsonpath='{.data.password}' | base64 -d; echo ")"; } || true
	@$(KUBECTL) -n gitlab get secret gitlab-root-password >/dev/null 2>&1 && { echo -n "  GitLab UI:      https://gitlab.$(WILDCARD)  (user root / "; $(KUBECTL) -n gitlab get secret gitlab-root-password -o jsonpath='{.data.password}' | base64 -d; echo ")"; } || true
	@$(KUBECTL) -n $(TEKTON_NS) get ingress tekton-results-api >/dev/null 2>&1 && echo "  Results API:    http://tekton-results.$(WILDCARD)" || true
	@echo ""
	@echo "--- portal env (run Portal from source with these) ---"
	@$(KUBECTL) -n $(TEKTON_NS) get ingress tekton-results-api >/dev/null 2>&1 && echo "    TEKTON_RESULTS_URL=http://tekton-results.$(WILDCARD)" || true
	@$(KUBECTL) -n $(NS) get ingress gitfusion >/dev/null 2>&1 && echo "    GITFUSION_URL=http://gitfusion.$(WILDCARD)" || echo "    GITFUSION_URL=(gitfusion ingress not found — run make krci)"
	@$(KUBECTL) -n $(MONITORING_NS) get ingress prometheus-kube-prometheus-prometheus >/dev/null 2>&1 && echo "    PROMETHEUS_URL=http://prometheus.$(WILDCARD)" || echo "    PROMETHEUS_URL=(prometheus ingress not found — run make prometheus)"
	@$(KUBECTL) -n $(SONAR_NS) get ingress sonar >/dev/null 2>&1 && echo "    SONAR_HOST_URL=http://sonar.$(WILDCARD)" || echo "    SONAR_HOST_URL=(sonar ingress not found — run make sonar)"
	@$(KUBECTL) -n $(NS) get secret ci-sonarqube >/dev/null 2>&1 && { echo -n "    SONAR_TOKEN="; $(KUBECTL) -n $(NS) get secret ci-sonarqube -o jsonpath='{.data.token}' | base64 -d; echo; } || echo "    SONAR_TOKEN=(ci-sonarqube secret not found — run make sonar-integrate)"

# ---- self-hosted git --------------------------------------------------------
# GitLab is a platform DEPENDENCY: gitlab-up runs BEFORE krci (so the chart can
# render the GitServer/EventListener from edp-tekton.gitServers and connect using
# the ci-gitlab secret); gitlab-integrate runs AFTER krci (operator CA + task fix
# + GitOps repo). `make testbed` chains them in the right order.
.PHONY: gitlab-up
gitlab-up: ## (pre-krci) Deploy GitLab + bootstrap creds/secrets + CoreDNS
	GITLAB_ROOT_PASSWORD='$(GITLAB_ROOT_PASSWORD)' bash scripts/gitlab-up.sh

.PHONY: gitlab-password
gitlab-password: ## Print the GitLab root credentials (local only)
	@echo -n "root / "; $(KUBECTL) -n gitlab get secret gitlab-root-password \
	  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d; echo

.PHONY: gitlab-integrate
gitlab-integrate: ## (post-krci) operator CA trust + gitlab-set-status fix + GitOps repo
	bash scripts/gitlab-integrate.sh

.PHONY: e2e
e2e: ## Validate end-to-end: MR -> review -> merge -> build -> deploy (demo/dev); PASS = all green + app deployed
	bash scripts/e2e.sh

.PHONY: gitlab-status
gitlab-status: ## Show GitLab + GitServer + EventListener + webhook state
	@echo "--- gitlab pod ---";    $(KUBECTL) -n gitlab get pods 2>/dev/null || echo "(not installed)"
	@$(KUBECTL) -n gitlab get secret gitlab-root-password >/dev/null 2>&1 && { echo -n "    GitLab UI: https://gitlab.$(WILDCARD)  (user root / "; $(KUBECTL) -n gitlab get secret gitlab-root-password -o jsonpath='{.data.password}' | base64 -d; echo " — local only)"; } || true
	@echo "--- gitserver ---";     $(KUBECTL) -n $(NS) get gitserver gitlab -o jsonpath='{.status}' 2>/dev/null; echo
	@echo "--- eventlistener ---"; $(KUBECTL) -n $(NS) get eventlistener edp-gitlab 2>/dev/null || echo "(none yet)"
	@echo "--- el ingress ---";    $(KUBECTL) -n $(NS) get ingress event-listener-gitlab 2>/dev/null || echo "(none yet)"
	@echo "--- coredns rewrites ---"; $(KUBECTL) -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep 'rewrite name' || true
	@echo "--- pipelineruns ---";  $(KUBECTL) -n $(NS) get pipelinerun 2>/dev/null | tail -8 || echo "(none)"

# ---- lifecycle --------------------------------------------------------------
.PHONY: up
up: preflight cluster ingress cert-manager tekton argocd ## Platform prerequisites (cluster + ingress + cert-manager + Tekton + Argo CD; no KRCI yet)
	@echo "Prerequisites up. Next: make testbed (adds deps + GitLab, then installs KRCI last)."

# Dependencies first, KRCI platform LAST (with values that wire it to them), then
# the post-install glue. Prerequisites build left-to-right (up installs Argo CD too):
#   up -> prometheus -> tekton-results -> sonar -> gitlab-up -> krci -> gitlab-integrate -> argocd-integrate -> sonar-integrate
.PHONY: testbed
testbed: up prometheus tekton-results sonar gitlab-up krci gitlab-integrate argocd-integrate sonar-integrate ## Full platform: deps first, KRCI (with gitServers/registry values) last
	@echo "Full platform up. KRCI installed last; GitServer/EventListener rendered from values. Validate: make e2e"

.PHONY: down
down: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)
