#!/usr/bin/env bash
# Phase: post-KRCI integration. Runs AFTER `make krci` (needs the codebase-operator,
# the edp-tekton tasks, and the chart-created GitServer/EventListener to exist).
# Pairs with scripts/gitlab-up.sh. Only the bits the Helm chart cannot express:
#   1. mount the GitLab CA into codebase-operator (no chart hook for its volumes;
#      gitfusion gets the same CA declaratively via gitfusion.volumes in values),
#   2. fix the upstream gitlab-set-status task (host parse + self-signed TLS),
#   3. onboard the krci-gitops Codebase (no `codebases` values section),
#   4. wire the GitLab Package Registry into the maven/python/npm/pnpm builds (settings
#      ConfigMaps + task patches; the Tasks are chart-owned, so Helm SSA resets them and
#      they are re-applied here). See docs/registry-integration.md.
# The GitServer/EventListener/Ingress themselves come from edp-tekton.gitServers.
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
GS_NAME="gitlab"
WILDCARD="${WILDCARD:-127.0.0.1.nip.io}"
GL_HOST="gitlab.${WILDCARD}"
KUBECTL="kubectl --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# The snapshot codebase-operator enforces SSH host key verification against its
# ssh-known-hosts ConfigMap (chart: knownHosts.*; no way to disable). GitLab
# generates host keys per install, so they cannot live in static values — pin them
# here from the running GitLab. The CM is chart-owned (a helm upgrade resets it;
# this step, like the other chart-owned patches below, re-applies) and the operator
# picks up CM edits without a restart. No-op in release mode (no such ConfigMap).
KH_CM="codebase-operator-ssh-known-hosts"
if $KUBECTL -n "$NS" get cm "$KH_CM" >/dev/null 2>&1; then
  echo "==> Pinning the GitLab SSH host keys ($GL_HOST, ports 22+32222) in cm $KH_CM"
  # Both address forms: the GitServer connect check dials :32222 (bracket form) while
  # git clone/push dials :22 (bare hostname form) — both go to the same gitlab svc.
  KNOWN="$($KUBECTL -n gitlab exec deploy/gitlab -- sh -c 'cat /etc/gitlab/ssh_host_*.pub' \
    | awk -v h="$GL_HOST" 'NF>=2 {print "["h"]:32222 "$1" "$2; print h" "$1" "$2}')"
  CUR="$($KUBECTL -n "$NS" get cm "$KH_CM" -o jsonpath='{.data.ssh_known_hosts}')"
  PATCH="$(CUR="$CUR" KNOWN="$KNOWN" HOST="$GL_HOST" python3 -c "
import json, os
cur, known, host = os.environ['CUR'], os.environ['KNOWN'], os.environ['HOST']
kept = [l for l in cur.splitlines()
        if not l.strip().startswith((host, '[' + host))]
merged = '\n'.join(kept).rstrip() + '\n' + known + '\n'
print(json.dumps({'data': {'ssh_known_hosts': merged}}) if merged != cur else '')")"
  if [ -n "$PATCH" ]; then
    $KUBECTL -n "$NS" patch cm "$KH_CM" -p "$PATCH"
  else
    echo "    already pinned"
  fi
fi

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

echo "==> Wiring the GitLab Package Registry into the build tasks"
# One schema for every language: PUBLISH to the codebase's own GitLab project registry,
# RESOLVE from the krci GROUP registry (a virtual aggregate over every project in the
# group). Two layers per language, mirroring what maven has always done here:
#   settings ConfigMap  — everything the ecosystem's own config language can express
#                         (URLs, credentials). Named gitlab-*-settings and referenced from
#                         values/edp-install.yaml (tekton.configs.*ConfigMap), so the chart
#                         neither renders nor owns them: a plain apply, no re-apply needed.
#   task patch          — only what that config language CANNOT express (per-build
#                         CI_PROJECT_ID, TLS trust). Chart-owned -> Helm SSA resets these
#                         on every `make krci`, hence --force-conflicts here.
# Needs secret ci-nexus + cm gitlab-ca (both from gitlab-up). docs/registry-integration.md.
for settings in maven npm python; do
  $KUBECTL apply -f "$HERE/manifests/gitlab-${settings}-settings.yaml" >/dev/null
done
echo "    settings: gitlab-{maven,npm,python}-settings applied (chart-independent)"

patch_task() {  # $1 = task name, $2 = what the patch buys it
  if ! $KUBECTL -n "$NS" get task "$1" >/dev/null 2>&1; then
    echo "    (skip) $1 task not found — run 'make krci' first"
    return 0
  fi
  $KUBECTL apply --server-side --force-conflicts -f "$HERE/manifests/$1-task-gitlab.yaml" >/dev/null
  echo "    $1: $2"
}

# edp-npm/edp-pnpm are the BUILD tasks: they only resolve (install) from the group
# registry, so they need the CA — and pnpm additionally needs to be told to read the
# .npmrc at all, which chart-stock never does.
patch_task maven    "publish -> projects/<codebase>, resolve -> groups/$NS"
patch_task python   "publish -> projects/<codebase>, resolve -> groups/$NS"
patch_task npm      "publish -> projects/<codebase>, resolve -> groups/$NS"
patch_task edp-npm  "resolve -> groups/$NS (build task: CA)"
patch_task edp-pnpm "resolve -> groups/$NS (build task: userconfig + CA)"

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
