#!/usr/bin/env bash
# Phase: post-KRCI integration. Runs AFTER `make krci` (needs the codebase-operator,
# the edp-tekton tasks, and the chart-created GitServer/EventListener to exist).
# Pairs with scripts/gitlab-up.sh. Only the bits the Helm chart cannot express:
#   1. mount the GitLab CA into codebase-operator (no chart hook for volumes),
#   2. fix the upstream gitlab-set-status task (host parse + self-signed TLS),
#   3. onboard the krci-gitops Codebase (no `codebases` values section).
# The GitServer/EventListener/Ingress themselves come from edp-tekton.gitServers.
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
GS_NAME="gitlab"
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

echo "==> Fixing the gitlab-set-status task (host parse + self-signed TLS)"
# Upstream task mis-parses our ssh://…:32222/… git URL (-> host "ssh") and verifies
# TLS against the self-signed cert, so pipelines abort at report-pipeline-start.
if $KUBECTL -n "$NS" get task gitlab-set-status >/dev/null 2>&1; then
  PATCH="$(python3 -c "import json;print(json.dumps([{'op':'replace','path':'/spec/steps/0/script','value':open('$HERE/scripts/gitlab-set-status.py').read()}]))")"
  $KUBECTL -n "$NS" patch task gitlab-set-status --type=json -p "$PATCH"
else
  echo "    (skip) gitlab-set-status task not found — run 'make krci' first"
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
echo "    Validate  : make e2e   (review pipeline; PASS = green except sonar)"
