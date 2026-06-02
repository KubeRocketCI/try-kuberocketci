#!/usr/bin/env bash
# Phase: post-KRCI integration. Runs AFTER `make krci` (needs the codebase-operator,
# the edp-tekton tasks, and the chart-created GitServer/EventListener to exist).
# Pairs with scripts/gitlab-up.sh. Only the bits the Helm chart cannot express:
#   1. mount the GitLab CA into codebase-operator (no chart hook for its volumes;
#      gitfusion gets the same CA declaratively via gitfusion.volumes in values),
#   2. fix the upstream gitlab-set-status task (host parse + self-signed TLS),
#   3. onboard the krci-gitops Codebase (no `codebases` values section),
#   4. wire the GitLab Package Registry into the maven build (settings ConfigMap +
#      maven task patch) — both chart-owned, so reset by Helm SSA and re-applied here.
# The GitServer/EventListener/Ingress themselves come from edp-tekton.gitServers.
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
GS_NAME="gitlab"
WILDCARD="${WILDCARD:-127.0.0.1.nip.io}"
GL_HOST="gitlab.${WILDCARD}"
KUBECTL="kubectl --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Waiting for the chart-rendered GitServer ($GS_NAME) to connect"
for _ in $(seq 1 60); do
  conn="$($KUBECTL -n "$NS" get gitserver "$GS_NAME" -o jsonpath='{.status.connected}' 2>/dev/null || true)"
  [ "$conn" = "true" ] && break
  sleep 5
done
echo "    gitserver/$GS_NAME connected=${conn:-<none>}"

echo "==> Trusting the GitLab self-signed CA in codebase-operator (cm gitlab-ca from gitlab-up)"
# The operator's GitLab REST client verifies TLS (skipWebhookSSLVerification covers
# only webhooks), so it must trust our self-signed CA or project/webhook creation
# fails with x509 "unknown authority". Mount the CA into /etc/ssl/certs (Go scans
# that dir IN ADDITION to the system bundle, so public CAs still work). Additive
# volume/mount → survives `make krci` (helm 3-way merge leaves it alone).
OP_CN="$($KUBECTL -n "$NS" get deploy codebase-operator -o jsonpath='{.spec.template.spec.containers[0].name}')"
$KUBECTL -n "$NS" patch deploy codebase-operator --type strategic -p "{\"spec\":{\"template\":{\"spec\":{\"volumes\":[{\"name\":\"gitlab-ca\",\"configMap\":{\"name\":\"gitlab-ca\"}}],\"containers\":[{\"name\":\"${OP_CN}\",\"volumeMounts\":[{\"name\":\"gitlab-ca\",\"mountPath\":\"/etc/ssl/certs/gitlab-ca.crt\",\"subPath\":\"gitlab-ca.crt\",\"readOnly\":true}]}]}}}}"
$KUBECTL -n "$NS" rollout status deploy/codebase-operator --timeout=120s
# (gitfusion gets the SAME GitLab CA, but DECLARATIVELY via gitfusion.volumes /
# volumeMounts in values/edp-install.yaml — applied at `make krci` time, so it trusts
# the CA on first start without a post-install patch. See that file for the rationale.)

echo "==> Fixing the gitlab-set-status task (host parse + self-signed TLS)"
# Upstream task mis-parses our ssh://…:32222/… git URL (-> host "ssh") and verifies
# TLS against the self-signed cert, so pipelines abort at report-pipeline-start.
if $KUBECTL -n "$NS" get task gitlab-set-status >/dev/null 2>&1; then
  PATCH="$(python3 -c "import json;print(json.dumps([{'op':'replace','path':'/spec/steps/0/script','value':open('$HERE/scripts/gitlab-set-status.py').read()}]))")"
  $KUBECTL -n "$NS" patch task gitlab-set-status --type=json -p "$PATCH"
else
  echo "    (skip) gitlab-set-status task not found — run 'make krci' first"
fi

echo "==> Wiring the GitLab Package Registry into the maven build"
# settings.xml -> GitLab (no Nexus mirror; Basic auth; group resolve; per-project
# deploy) and the maven task patch (CA trust + CI_PROJECT_ID + wagon transport, none
# expressible in settings.xml). Both are chart-owned, so Helm SSA resets them on every
# `make krci` -> re-applied here with --force-conflicts. Needs secret ci-nexus (gitlab-up)
# and cm gitlab-ca (gitlab-up). See docs/registry-integration.md.
sed -e "s#__GL_HOST__#${GL_HOST}#g" -e "s#__GROUP__#${NS}#g" \
  "$HERE/manifests/custom-maven-settings.yaml" | $KUBECTL apply --server-side --force-conflicts -f -
if $KUBECTL -n "$NS" get task maven >/dev/null 2>&1; then
  $KUBECTL apply --server-side --force-conflicts -f "$HERE/manifests/maven-task-gitlab.yaml" >/dev/null
  echo "    maven task patched (trust-gitlab-ca + wagon); settings -> https://$GL_HOST group/$NS"
else
  echo "    (skip) maven task not found — run 'make krci' first"
fi

echo "==> Onboarding the KubeRocketCI GitOps repository ($NS/krci-gitops)"
# The codebase-operator was just restarted (CA patch), so its Codebase validating
# webhook (vcodebase.kb.io) may not be serving for a few seconds even though the
# Deployment reports Available -> a bare apply races with "context deadline exceeded".
# Poll a server-side dry-run (which invokes the webhook) until it succeeds, then apply.
for _ in $(seq 1 30); do
  $KUBECTL apply --dry-run=server -f "$HERE/manifests/krci-gitops.yaml" >/dev/null 2>&1 && break
  echo "    codebase webhook not serving yet; waiting..."
  sleep 5
done
$KUBECTL apply -f "$HERE/manifests/krci-gitops.yaml"

echo ""
echo "==> gitlab-integrate done."
echo "    GitServer : $GS_NAME  -> kubectl -n $NS get gitservers"
echo "    Webhook   : EventListener edp-$GS_NAME (chart-managed), host el-$GS_NAME-$NS.<wildcard>"
echo "    GitOps    : $NS/krci-gitops    Registry: gitlab.<wildcard>:5050 -> /$NS/<codebase>"
echo "    Validate  : make e2e   (MR -> review -> merge -> build -> deploy demo/dev; PASS = all green)"
