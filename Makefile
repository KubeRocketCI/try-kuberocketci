# KubeRocketCI local test harness — kind + KubeRocketCI on Docker Desktop (macOS).
# Run `make help` for the workflow. Typical first run:  make up
SHELL := /bin/bash
.ONESHELL:
.DEFAULT_GOAL := help

# ---- config -----------------------------------------------------------------
CLUSTER            ?= krci
CTX                ?= kind-$(CLUSTER)
# Kubernetes version = the kind node image; digest from the kind release notes image list
# (https://github.com/kubernetes-sigs/kind/releases). Requires kind >= 0.32.
KIND_NODE_IMAGE    ?= kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
NS                 ?= krci
WILDCARD           ?= 127.0.0.1.nip.io
EDP_VERSION        ?= 3.15.0
HELM_REPO_NAME     ?= epamedp
HELM_REPO_URL      ?= https://epam.github.io/edp-helm-charts/stable
# ingress-nginx is retired upstream; this is the final release. Its support table ends at
# k8s 1.35; it uses the stable networking.k8s.io/v1 API only.
INGRESS_NGINX_REF  ?= controller-v1.15.1
# Supported k8s: 1.33-1.36.
CERT_MANAGER_VER   ?= v1.21.2
CERT_MANAGER_MANIFEST ?= https://github.com/cert-manager/cert-manager/releases/download/$(CERT_MANAGER_VER)/cert-manager.yaml
# Argo CD (KRCI CD engine); Argo CD 3.5 is tested on k8s 1.33-1.36. Chart >= 10 defaults
# global.networkPolicy.create=true; values/argo-cd.yaml (single instance) sets it false.
ARGOCD_REPO_NAME   ?= argo
ARGOCD_REPO_URL    ?= https://argoproj.github.io/argo-helm
ARGOCD_CHART_VERSION ?= 10.9.2
ARGOCD_NS          ?= argocd
# Pipelines: the v1.6 LTS line KubeRocketCI docs validate edp-tekton against, latest patch.
# Triggers/interceptors: current release. Manifests come from the GitHub release assets;
# the legacy storage.googleapis.com/tekton-releases bucket is frozen at Pipelines v1.6.0 /
# Triggers v0.34.0.
TEKTON_PIPELINE    ?= https://github.com/tektoncd/pipeline/releases/download/v1.6.7/release.yaml
TEKTON_TRIGGERS    ?= https://github.com/tektoncd/triggers/releases/download/v0.37.1/release.yaml
TEKTON_INTERCEPT   ?= https://github.com/tektoncd/triggers/releases/download/v0.37.1/interceptors.yaml
# Tekton Results — KRCI manifest copied verbatim from edp-cluster-add-ons
# (clusters/core/addons/tekton/results.yaml): api-config ConfigMap included, TLS disabled.
# DB: manifests/tekton-results-postgres.yaml fulfils the manifest's Postgres contract.
TEKTON_RESULTS_MANIFEST ?= manifests/tekton-results.yaml
TEKTON_NS          ?= tekton-pipelines
# kube-prometheus-stack. Chart 90 renamed the serviceMonitor auth/tls keys;
# values/kube-prometheus-stack.yaml uses none of them.
PROM_REPO_NAME     ?= prometheus-community
PROM_REPO_URL      ?= https://prometheus-community.github.io/helm-charts
PROM_CHART_VERSION ?= 91.5.2
MONITORING_NS      ?= monitoring
# SonarQube (KRCI code-quality engine); chart kubeVersion >= 1.24. The community-branch-plugin
# + webapp pins in values/sonarqube.yaml track the SonarQube image version; bump together.
# DB: manifests/sonar-postgres.yaml. sonar-operator + its CRs add the quality gate / ci-user.
SONAR_REPO_NAME    ?= sonarqube
SONAR_REPO_URL     ?= https://SonarSource.github.io/helm-chart-sonarqube
SONAR_CHART_VERSION ?= 2025.3.1
SONAR_OPERATOR_VERSION ?= 3.4.0
SONAR_NS           ?= sonar
# Images `preload` pulls into the host docker cache (survives `make down`) and loads into
# the node, whose containerd cache dies with the cluster (GitLab CE is ~3GB). Parsed from
# the manifest: the image pin lives in one place.
PRELOAD_IMAGES     ?= $(shell awk '/image: gitlab\/gitlab-ce/{print $$2}' manifests/gitlab.yaml)
# LOCAL-ONLY GitLab root password, seeded on first install. GitLab 17.x rejects passwords
# containing the app name ("gitlab") or the username ("root") as "commonly used".
GITLAB_ROOT_PASSWORD ?= KrciLocal_2026!
# GitLab Runner (Kubernetes executor) for the GitLab CI path (Codebase ciTool=gitlab);
# KubeRocketCI bundles no runner. Chart appVersion must match the GitLab CE version in
# manifests/gitlab.yaml.
GITLAB_RUNNER_CHART_VERSION ?= 0.70.5
# Envoy Gateway (Gateway API traffic engine; Portal Networking tab). The gateway-helm OCI
# chart installs the Gateway API + Envoy Gateway CRDs and the controller, no GatewayClass:
# `make envoy` applies manifests/envoy-gatewayclass.yaml. v1.9.x: Gateway API v1.6.1;
# k8s 1.33-1.36.
ENVOY_GATEWAY_VERSION ?= v1.9.1
ENVOY_GATEWAY_NS      ?= envoy-gateway-system
VALUES             ?= values/edp-install.yaml
# Snapshot mode (`SNAPSHOT=true make testbed`): KRCI from the snapshot helm repo, one release
# per chart (the edp-install umbrella renders only the shared base, all subcharts disabled);
# the per-chart layout of edp-delivery-gitops/tekton/dev. From scratch only: one mode per
# cluster, `make down` to switch. Latest snapshot (--devel) unless
# SNAP_VERSION_<chart>=x.y.z-SNAPSHOT.n is set.
SNAPSHOT             ?= false
SNAP_HELM_REPO_NAME  ?= epamedp-snapshot
SNAP_HELM_REPO_URL   ?= https://epam.github.io/edp-helm-charts/snapshot
# Install order: CRD-owning operators first (codebase-operator: GitServer, QuickLink,
# Codebase; cd-pipeline-operator: CDPipeline, Stage). The umbrella base (QuickLink CRs) and
# edp-tekton (GitServer CR) reference those CRDs.
SNAPSHOT_CRD_CHARTS  ?= codebase-operator cd-pipeline-operator
SNAPSHOT_CHARTS      ?= edp-tekton gitfusion krci-portal
# Snapshot mode covers edp-install and its subcharts only; sonar-operator always installs
# from the stable repo at its pin. Captured before the SNAPSHOT override below.
STABLE_HELM_REPO_NAME := $(HELM_REPO_NAME)
STABLE_HELM_REPO_URL  := $(HELM_REPO_URL)
ifeq ($(SNAPSHOT),true)
HELM_REPO_NAME := $(SNAP_HELM_REPO_NAME)
HELM_REPO_URL  := $(SNAP_HELM_REPO_URL)
VALUES         := values/snapshot/edp-install.yaml
EDP_VERSION_FLAG := --devel
else
EDP_VERSION_FLAG := --version $(EDP_VERSION)
endif
KUBECTL            := kubectl --context $(CTX)
HELM               := helm --kube-context $(CTX)

# ---- meta -------------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Quick start:    make preflight && make testbed && make token"
	@echo "Snapshot mode:  SNAPSHOT=true make testbed   (from scratch only; one chart: make snapshot-<chart>, pin: SNAP_VERSION_<chart>=x.y.z-SNAPSHOT.n)"

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
cluster: ## Create the kind cluster (node image from KIND_NODE_IMAGE; ports 80/443 -> localhost)
	@if kind get clusters 2>/dev/null | grep -qx $(CLUSTER); then \
	  echo "cluster '$(CLUSTER)' already exists"; \
	else \
	  kind create cluster --config kind/cluster.yaml --image $(KIND_NODE_IMAGE); \
	fi
	$(KUBECTL) cluster-info

.PHONY: ingress
ingress: ## Install ingress-nginx (kind provider) and wait
	$(KUBECTL) apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/$(INGRESS_NGINX_REF)/deploy/static/provider/kind/deploy.yaml
	$(KUBECTL) -n ingress-nginx wait --for=condition=Available deploy/ingress-nginx-controller --timeout=300s
	# The controller reports Available before its admission webhook endpoints serve; the next
	# Ingress create (argocd) then fails with "connection refused". Wait for a ready endpoint.
	@echo "waiting for ingress-nginx admission webhook endpoints..."
	@for i in $$(seq 1 90); do \
	  ips=$$($(KUBECTL) -n ingress-nginx get endpointslices -l kubernetes.io/service-name=ingress-nginx-controller-admission -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[*]}' 2>/dev/null); \
	  [ -n "$$ips" ] && { echo "  admission webhook ready: $$ips"; exit 0; }; \
	  sleep 2; \
	done; \
	echo "!! ingress-nginx admission webhook endpoints never became ready" >&2; exit 1

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
	# The admission webhook must serve before KubeRocketCI applies its Pipeline CRs; otherwise
	# helm install fails with "connection refused" on webhook.pipeline.tekton.dev.
	$(KUBECTL) -n tekton-pipelines rollout status deploy/tekton-pipelines-webhook --timeout=300s
	$(KUBECTL) -n tekton-pipelines wait --for=condition=Available \
	  deploy/tekton-pipelines-webhook deploy/tekton-triggers-webhook --timeout=300s

.PHONY: argocd
argocd: ## Install Argo CD (chart $(ARGOCD_CHART_VERSION), single instance) + krci AppProject
	helm repo add $(ARGOCD_REPO_NAME) $(ARGOCD_REPO_URL) 2>/dev/null || true
	helm repo update $(ARGOCD_REPO_NAME)
	$(HELM) upgrade --install argocd $(ARGOCD_REPO_NAME)/argo-cd \
	  --version $(ARGOCD_CHART_VERSION) -n $(ARGOCD_NS) --create-namespace \
	  -f values/argo-cd.yaml --wait --timeout 600s
	# The AppProject cannot be expressed in chart values.
	$(KUBECTL) apply -f manifests/argocd-appproject-krci.yaml
	# apps-in-any-namespace: the appset controller needs cluster-wide read on
	# applications/appprojects; the chart does not grant it (edp-cluster-add-ons rbac-hack).
	$(KUBECTL) apply -f manifests/argocd-appset-rbac.yaml
	$(KUBECTL) -n $(ARGOCD_NS) get pods
	@echo "Argo CD UI: http://argocd.$(WILDCARD)   (user admin; password via 'make status')"

.PHONY: argocd-integrate
argocd-integrate: ## (post-krci) Register the GitLab repo creds + create the ci-argocd secret in ns krci
	ARGOCD_REPO_NAME='$(ARGOCD_REPO_NAME)' ARGOCD_REPO_URL='$(ARGOCD_REPO_URL)' \
	  ARGOCD_CHART_VERSION='$(ARGOCD_CHART_VERSION)' ARGOCD_NS='$(ARGOCD_NS)' \
	  bash scripts/argocd-integrate.sh

# ---- KubeRocketCI -----------------------------------------------------------
.PHONY: repo
repo: ## Add/update the KubeRocketCI helm repo
	helm repo add $(HELM_REPO_NAME) $(HELM_REPO_URL) 2>/dev/null || true
	helm repo update $(HELM_REPO_NAME)

.PHONY: repo-snapshot
repo-snapshot: ## Add/update the KubeRocketCI SNAPSHOT helm repo
	helm repo add $(SNAP_HELM_REPO_NAME) $(SNAP_HELM_REPO_URL) 2>/dev/null || true
	helm repo update $(SNAP_HELM_REPO_NAME)

.PHONY: snapshot-versions
snapshot-versions: repo-snapshot ## Show the latest SNAPSHOT chart versions
	helm search repo $(SNAP_HELM_REPO_NAME) --devel

# One chart from the snapshot repo (`make snapshot-edp-tekton`). Release name = chart name:
# resource names match the umbrella's, so status/e2e/integrate targets work unchanged.
# Latest snapshot unless SNAP_VERSION_<chart> is set.
snapshot-%: repo-snapshot
	$(HELM) upgrade --install $* $(SNAP_HELM_REPO_NAME)/$* \
	  $(if $(SNAP_VERSION_$*),--version $(SNAP_VERSION_$*),--devel) \
	  -n $(NS) --create-namespace \
	  -f values/snapshot/global.yaml -f values/snapshot/$*.yaml \
	  --force-conflicts --wait --timeout 900s

.PHONY: krci-dry-run
krci-dry-run: repo ## Render the chart (no install) to reveal required values
	$(HELM) upgrade --install edp $(HELM_REPO_NAME)/edp-install \
	  $(EDP_VERSION_FLAG) -n $(NS) --create-namespace \
	  -f $(VALUES) --dry-run --debug 2>&1 | tail -60

.PHONY: krci
krci: repo ## Install KubeRocketCI (edp-install $(EDP_VERSION), or SNAPSHOT=true for per-chart snapshots); renders GitServer/EL + in-cluster Portal (run gitlab-up first)
	# Portal env secret must exist before the chart (envFrom on a missing Secret blocks the pod).
	$(KUBECTL) create namespace $(NS) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) -n $(NS) apply -f manifests/krci-portal-secret.yaml
ifeq ($(SNAPSHOT),true)
	# CRD-owning operators first: the umbrella base renders QuickLink CRs and edp-tekton a
	# GitServer CR.
	$(MAKE) $(addprefix snapshot-,$(SNAPSHOT_CRD_CHARTS))
endif
	# --force-conflicts: Helm 4 SSA conflicts with the post-krci kubectl patches on
	# gitlab-set-status / deploy-applicationset-cli; the *-integrate steps re-apply them.
	$(HELM) upgrade --install edp $(HELM_REPO_NAME)/edp-install \
	  $(EDP_VERSION_FLAG) -n $(NS) --create-namespace \
	  -f $(VALUES) --force-conflicts --wait --timeout 900s
ifeq ($(SNAPSHOT),true)
	# Remaining component charts as their own releases.
	$(MAKE) $(addprefix snapshot-,$(SNAPSHOT_CHARTS))
endif
	$(KUBECTL) -n $(NS) get pods

# ---- platform capabilities --------------------------------------------------
.PHONY: prometheus
prometheus: ## Install kube-prometheus-stack ($(PROM_CHART_VERSION)) + Grafana
	helm repo add $(PROM_REPO_NAME) $(PROM_REPO_URL) 2>/dev/null || true
	helm repo update $(PROM_REPO_NAME)
	$(HELM) upgrade --install prometheus $(PROM_REPO_NAME)/kube-prometheus-stack \
	  --version $(PROM_CHART_VERSION) -n $(MONITORING_NS) --create-namespace \
	  -f values/kube-prometheus-stack.yaml --wait --timeout 600s
	$(KUBECTL) -n $(MONITORING_NS) get pods

.PHONY: tekton-results
tekton-results: ## Install Tekton Results (v0.20.0, KRCI manifest) + minimal Postgres
	# Order: Postgres + DB secret (the manifest's results-primary / results-pguser-results
	# contract) before the Results manifest. The api ConfigMap is in the manifest; TLS disabled.
	$(KUBECTL) apply -f manifests/tekton-results-postgres.yaml
	$(KUBECTL) -n $(TEKTON_NS) rollout status deploy/results-primary --timeout=300s
	$(KUBECTL) apply -f $(TEKTON_RESULTS_MANIFEST)
	$(KUBECTL) -n $(TEKTON_NS) rollout status deploy/tekton-results-api --timeout=300s
	$(KUBECTL) -n $(TEKTON_NS) rollout status deploy/tekton-results-watcher --timeout=300s
	# Stable nip.io URL for the Portal's Results reads.
	$(KUBECTL) apply -f manifests/tekton-results-ingress.yaml
	$(KUBECTL) -n $(TEKTON_NS) get pods | grep -E 'results|NAME'
	@echo "Tekton Results API: http://tekton-results.$(WILDCARD)  (set TEKTON_RESULTS_URL to this)"

.PHONY: sonar
sonar: ## Install SonarQube (chart $(SONAR_CHART_VERSION)) + own Postgres + sonar-operator + CRs (always stable, SNAPSHOT-independent)
	# Order: Postgres (the add-ons sonar-primary / sonar-pguser-sonar contract), SonarQube
	# (external jdbc), sonar-operator + its CRs (Sonar/Group/PermissionTemplate/QualityGate/User).
	$(KUBECTL) apply -f manifests/sonar-postgres.yaml
	$(KUBECTL) -n $(SONAR_NS) rollout status deploy/sonar-primary --timeout=300s
	# Admin secret before the chart: the post-install hook reads it to set the admin password
	# on first startup; the sonar-operator authenticates with the same secret.
	$(KUBECTL) apply -f manifests/sonar-admin-secret.yaml
	helm repo add $(SONAR_REPO_NAME) $(SONAR_REPO_URL) 2>/dev/null || true
	helm repo update $(SONAR_REPO_NAME)
	$(HELM) upgrade --install sonar $(SONAR_REPO_NAME)/sonarqube \
	  --version $(SONAR_CHART_VERSION) -n $(SONAR_NS) --create-namespace \
	  -f values/sonarqube.yaml --wait --timeout 900s
	helm repo add $(STABLE_HELM_REPO_NAME) $(STABLE_HELM_REPO_URL) 2>/dev/null || true
	helm repo update $(STABLE_HELM_REPO_NAME)
	$(HELM) upgrade --install sonar-operator $(STABLE_HELM_REPO_NAME)/sonar-operator \
	  --version $(SONAR_OPERATOR_VERSION) -n $(SONAR_NS) --wait --timeout 300s
	$(KUBECTL) apply -f manifests/sonar-operator-crs.yaml
	$(KUBECTL) -n $(SONAR_NS) get pods
	@echo "SonarQube UI: https://sonar.$(WILDCARD)  (user admin; password via 'make status')"

.PHONY: sonar-integrate
sonar-integrate: ## (post-krci) Mint a token + create the ci-sonarqube secret in ns krci
	bash scripts/sonar-integrate.sh

# ---- access -----------------------------------------------------------------
.PHONY: token
token: ## Mint a 24h cluster-admin token for Portal login (local only)
	@$(KUBECTL) -n $(NS) get sa krci-admin >/dev/null 2>&1 || $(KUBECTL) -n $(NS) create sa krci-admin
	$(KUBECTL) get clusterrolebinding krci-admin >/dev/null 2>&1 || \
	  $(KUBECTL) create clusterrolebinding krci-admin --clusterrole=cluster-admin --serviceaccount=$(NS):krci-admin
	@echo "----- BEARER TOKEN (paste into the Portal 'Sign In with Token' dialog) -----"
	@$(KUBECTL) -n $(NS) create token krci-admin --duration=24h

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
	@$(KUBECTL) -n $(SONAR_NS) get ingress sonar >/dev/null 2>&1 && { echo -n "  SonarQube UI:   https://sonar.$(WILDCARD)  (user admin / "; $(KUBECTL) -n $(SONAR_NS) get secret sonar-admin-password -o jsonpath='{.data.password}' | base64 -d; echo ")"; } || true
	@$(KUBECTL) -n gitlab get secret gitlab-root-password >/dev/null 2>&1 && { echo -n "  GitLab UI:      https://gitlab.$(WILDCARD)  (user root / "; $(KUBECTL) -n gitlab get secret gitlab-root-password -o jsonpath='{.data.password}' | base64 -d; echo ")"; } || true
	@$(KUBECTL) -n $(TEKTON_NS) get ingress tekton-results-api >/dev/null 2>&1 && echo "  Results API:    http://tekton-results.$(WILDCARD)" || true
	@$(KUBECTL) -n $(MONITORING_NS) get ingress prometheus-grafana >/dev/null 2>&1 && { echo -n "  Grafana UI:     http://grafana.$(WILDCARD)  (user admin / "; $(KUBECTL) -n $(MONITORING_NS) get secret prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo ")"; } || true
	@$(KUBECTL) -n $(NS) get ingress krci-portal >/dev/null 2>&1 && echo "  Portal UI:      https://portal.$(WILDCARD)  (HTTPS/self-signed; sign in with the ServiceAccount token from 'make token')" || true
	@echo ""
	@echo "--- portal .env values ---"
	@$(KUBECTL) -n $(TEKTON_NS) get ingress tekton-results-api >/dev/null 2>&1 && echo "    TEKTON_RESULTS_URL=http://tekton-results.$(WILDCARD)" || true
	@$(KUBECTL) -n $(NS) get ingress gitfusion >/dev/null 2>&1 && echo "    GITFUSION_URL=http://gitfusion.$(WILDCARD)" || echo "    GITFUSION_URL=(gitfusion ingress not found — run make krci)"
	@$(KUBECTL) -n $(MONITORING_NS) get ingress prometheus-kube-prometheus-prometheus >/dev/null 2>&1 && echo "    PROMETHEUS_URL=http://prometheus.$(WILDCARD)" || echo "    PROMETHEUS_URL=(prometheus ingress not found — run make prometheus)"
	@$(KUBECTL) -n $(SONAR_NS) get ingress sonar >/dev/null 2>&1 && echo "    SONAR_HOST_URL=https://sonar.$(WILDCARD)" || echo "    SONAR_HOST_URL=(sonar ingress not found — run make sonar)"
	@$(KUBECTL) -n $(NS) get secret ci-sonarqube >/dev/null 2>&1 && { echo -n "    SONAR_TOKEN="; $(KUBECTL) -n $(NS) get secret ci-sonarqube -o jsonpath='{.data.token}' | base64 -d; echo; } || echo "    SONAR_TOKEN=(ci-sonarqube secret not found — run make sonar-integrate)"

# ---- self-hosted git --------------------------------------------------------
# GitLab is a platform dependency. gitlab-up runs before krci: the chart renders the
# GitServer/EventListener from edp-tekton.gitServers and connects with the ci-gitlab secret.
# gitlab-integrate runs after krci: operator CA, task patches, GitOps repo. `make testbed`
# chains them in order.
.PHONY: preload
preload: ## Load the GitLab image from the host docker cache into kind (skips the ~3GB pull)
	@for img in $(PRELOAD_IMAGES); do \
	  docker image inspect "$$img" >/dev/null 2>&1 || docker pull --platform linux/amd64 "$$img"; \
	  if docker exec $(CLUSTER)-control-plane ctr -n k8s.io images ls -q 2>/dev/null | grep -qF "$$img"; then \
	    echo "  $$img already in the kind node"; \
	  else \
	    kind load docker-image "$$img" --name $(CLUSTER); \
	  fi; \
	done

.PHONY: gitlab-up
gitlab-up: preload ## (pre-krci) Deploy GitLab + bootstrap creds/secrets + CoreDNS
	GITLAB_ROOT_PASSWORD='$(GITLAB_ROOT_PASSWORD)' bash scripts/gitlab-up.sh

.PHONY: gitlab-integrate
gitlab-integrate: ## (post-krci) operator CA trust + gitlab-set-status fix + GitOps repo
	bash scripts/gitlab-integrate.sh

.PHONY: e2e
e2e: ## Validate end-to-end: MR -> review -> merge -> build -> deploy (demo/dev); PASS = all green + app deployed
	bash scripts/e2e.sh

.PHONY: e2e-java
e2e-java: ## Validate Java/Maven -> GitLab Package Registry: onboard -> MR -> review -> merge -> build (registry tasks green; docker image build is a known arm64 base-image issue)
	bash scripts/e2e-java.sh

# ---- GitLab CI (alternative CI engine to Tekton) ----------------------------
# A Codebase with spec.ciTool=gitlab runs its CI in GitLab CI: the operator injects
# .gitlab-ci.yml and skips the Tekton EventListener. `make gitlab-ci` installs the runner
# and onboards the app; `make e2e-gitlabci` validates.
.PHONY: gitlab-ci
gitlab-ci: ## (GitLab CI) Set up CI in GitLab CI instead of Tekton: install the runner + onboard the Java app
	GITLAB_RUNNER_CHART_VERSION='$(GITLAB_RUNNER_CHART_VERSION)' bash scripts/gitlab-runner.sh
	bash scripts/gitlab-ci-onboard.sh

.PHONY: e2e-gitlabci
e2e-gitlabci: ## (GitLab CI) Validate GitLab CI instead of Tekton: MR -> review pipeline green -> merge -> build pipeline green
	bash scripts/e2e-gitlabci.sh

.PHONY: gitlab-status
gitlab-status: ## Show GitLab + GitServer + EventListener + webhook state
	@echo "--- gitlab pod ---";    $(KUBECTL) -n gitlab get pods 2>/dev/null || echo "(not installed)"
	@$(KUBECTL) -n gitlab get secret gitlab-root-password >/dev/null 2>&1 && { echo -n "    GitLab UI: https://gitlab.$(WILDCARD)  (user root / "; $(KUBECTL) -n gitlab get secret gitlab-root-password -o jsonpath='{.data.password}' | base64 -d; echo " — local only)"; } || true
	@echo "--- gitserver ---";     $(KUBECTL) -n $(NS) get gitserver gitlab -o jsonpath='{.status}' 2>/dev/null; echo
	@echo "--- eventlistener ---"; $(KUBECTL) -n $(NS) get eventlistener edp-gitlab 2>/dev/null || echo "(none yet)"
	@echo "--- el ingress ---";    $(KUBECTL) -n $(NS) get ingress event-listener-gitlab 2>/dev/null || echo "(none yet)"
	@echo "--- coredns rewrites ---"; $(KUBECTL) -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep 'rewrite name' || true
	@echo "--- pipelineruns ---";  $(KUBECTL) -n $(NS) get pipelinerun 2>/dev/null | tail -8 || echo "(none)"
	@echo "--- gitlab runner (GitLab CI path) ---"; $(KUBECTL) -n gitlab-runner get pods 2>/dev/null | grep -E 'gitlab-runner|NAME' || echo "(not installed — run make gitlab-ci)"
	@echo "--- gitlab-ci codebase ---"; $(KUBECTL) -n $(NS) get codebase java-gitlabci-app 2>/dev/null || echo "(none — run make gitlab-ci)"

# ---- Envoy Gateway (Gateway API traffic engine) -----------------------------
# Gateway-API counterpart of `make ingress`: controller, CRDs, the 'eg' GatewayClass and the
# PodMonitor for Envoy proxy metrics. Applications own their Gateway/HTTPRoute objects.
# Opt-in: not part of `make up`/`testbed`.
.PHONY: envoy
envoy: ## Install Envoy Gateway (Gateway API + Envoy CRDs + controller + 'eg' GatewayClass) + proxy metrics PodMonitor
	$(HELM) upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
	  --version $(ENVOY_GATEWAY_VERSION) -n $(ENVOY_GATEWAY_NS) --create-namespace \
	  --wait --timeout 300s
	$(KUBECTL) -n $(ENVOY_GATEWAY_NS) rollout status deploy/envoy-gateway --timeout=300s
	$(KUBECTL) apply -f manifests/envoy-gatewayclass.yaml
	$(KUBECTL) wait --for=condition=Accepted gatewayclass/eg --timeout=120s
	$(KUBECTL) apply -f manifests/envoy-metrics-podmonitor.yaml

# ---- lifecycle --------------------------------------------------------------
.PHONY: up
up: preflight cluster ingress cert-manager tekton argocd ## Platform prerequisites (cluster + ingress + cert-manager + Tekton + Argo CD; no KRCI yet)
	@echo "Prerequisites up. Next: make testbed (adds deps + GitLab, then installs KRCI last)."

# Dependencies first, KRCI last (its values reference them), then the post-install glue:
#   up -> prometheus -> tekton-results -> sonar -> gitlab-up -> krci -> gitlab-integrate -> argocd-integrate -> sonar-integrate
.PHONY: testbed
testbed: up prometheus tekton-results sonar gitlab-up krci gitlab-integrate argocd-integrate sonar-integrate ## Full platform: deps first, KRCI (with gitServers/registry values) last
	@echo "Full platform up. KRCI installed last; GitServer/EventListener rendered from values. Validate: make e2e"

.PHONY: down
down: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)
