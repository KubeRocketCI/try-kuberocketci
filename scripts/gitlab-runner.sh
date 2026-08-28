#!/usr/bin/env bash
# Install + register a GitLab Runner (Kubernetes executor) for the KubeRocketCI
# GitLab CI path. Pairs with scripts/gitlab-ci-onboard.sh (component mirror + app)
# and scripts/e2e-gitlabci.sh (the e2e).
#
# Why this exists: with Codebase spec.ciTool=gitlab the codebase-operator skips the
# Tekton EventListener and pushes a .gitlab-ci.yml instead, so CI runs as GitLab CI
# jobs. GitLab CE 17.5 already serves CI; the only missing piece is a runner to
# execute the jobs. KubeRocketCI does not bundle one.
#
# What it does (idempotent):
#   1. namespace + GitLab CA secret the runner trusts (from secret gitlab-tls),
#   2. mint a GitLab 17.x runner AUTH token (POST /api/v4/user/runners,
#      runner_type=instance_type) using the root PAT in secret ci-gitlab,
#   3. helm install gitlab/gitlab-runner with that token (values/gitlab-runner.yaml),
#   4. wait for the runner pod Ready and the runner to report online.
# It does NOT install QEMU/binfmt — the pipeline builds native arm64 (see the NOTE below).
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
GL_NS="gitlab"
RUNNER_NS="${RUNNER_NS:-gitlab-runner}"
WILDCARD="${WILDCARD:-127.0.0.1.nip.io}"
GL_HOST="gitlab.${WILDCARD}"
CHART_VERSION="${GITLAB_RUNNER_CHART_VERSION:-0.70.5}"
KUBECTL="kubectl --context $CTX"
HELM="helm --kube-context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

GLPOD="$($KUBECTL -n $GL_NS get pod -l app=gitlab -o jsonpath='{.items[0].metadata.name}')"
PAT="$($KUBECTL -n $NS get secret ci-gitlab -o jsonpath='{.data.token}' | base64 -d)"

# Run a GitLab REST call from inside the gitlab pod (self-signed https://localhost).
gl_api() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then $KUBECTL -n $GL_NS exec "$GLPOD" -- curl -sk -X "$m" -H "PRIVATE-TOKEN: $PAT" -H 'Content-Type: application/json' -d "$b" "https://localhost/api/v4/$p"
  else $KUBECTL -n $GL_NS exec "$GLPOD" -- curl -sk -X "$m" -H "PRIVATE-TOKEN: $PAT" "https://localhost/api/v4/$p"; fi; }

echo "==> Namespace $RUNNER_NS + GitLab CA secret (gitlab-runner-certs)"
$KUBECTL get ns "$RUNNER_NS" >/dev/null 2>&1 || $KUBECTL create ns "$RUNNER_NS"
# The runner trusts the GitLab self-signed cert via a secret whose key is "<host>.crt".
# gitlab-tls is self-signed with CA:TRUE, so its tls.crt doubles as the CA.
$KUBECTL -n $GL_NS get secret gitlab-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/gitlab-runner-ca.crt
$KUBECTL -n "$RUNNER_NS" create secret generic gitlab-runner-certs \
  --from-file="${GL_HOST}.crt=/tmp/gitlab-runner-ca.crt" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
rm -f /tmp/gitlab-runner-ca.crt

echo "==> Minting a runner authentication token (instance runner; idempotent)"
# GitLab 17.x: registration tokens are gone — create a runner object, get its auth
# token (glrt-…). Revoke prior 'krci-kubernetes' instance runners first so re-runs
# don't pile up dead runners. run_untagged=true so it picks up the pipeline's
# (untagged) jobs; locked=false so any project can use it.
for id in $(gl_api GET "runners/all?type=instance_type" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
print(" ".join(str(r["id"]) for r in d if r.get("description")=="krci-kubernetes"))'); do
  gl_api DELETE "runners/$id" >/dev/null 2>&1 || true
done
RUNNER_TOKEN="$(gl_api POST "user/runners" \
  '{"runner_type":"instance_type","description":"krci-kubernetes","run_untagged":true,"locked":false,"tag_list":[]}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))')"
[ -n "$RUNNER_TOKEN" ] || { echo "!! could not mint runner token" >&2; exit 1; }
echo "    runner token: ${RUNNER_TOKEN:0:8}…"

echo "==> Installing gitlab/gitlab-runner (chart $CHART_VERSION)"
helm repo add gitlab https://charts.gitlab.io >/dev/null 2>&1 || true
helm repo update gitlab >/dev/null 2>&1
$HELM upgrade --install gitlab-runner gitlab/gitlab-runner \
  --version "$CHART_VERSION" -n "$RUNNER_NS" \
  -f "$HERE/values/gitlab-runner.yaml" \
  --set runnerToken="$RUNNER_TOKEN" \
  --wait --timeout 300s

# NOTE: do NOT add a `tonistiigi/binfmt --install amd64` step here. It replaces Rosetta
# with qemu-x86_64 in the shared VM kernel, which crashes GitLab's gitaly — the pipeline
# builds native arm64 precisely so no emulation is needed. Full story: docs/gitlab-ci.md.

echo "==> Waiting for the runner to report online"
ONLINE=""
for _ in $(seq 1 30); do
  ONLINE="$(gl_api GET "runners/all?type=instance_type" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
print("yes" if any(r.get("description")=="krci-kubernetes" and r.get("online") for r in d) else "")')"
  [ -n "$ONLINE" ] && break
  sleep 5
done

echo ""
echo "==> gitlab-runner done."
$KUBECTL -n "$RUNNER_NS" get pods
[ -n "$ONLINE" ] && echo "    Runner 'krci-kubernetes' is ONLINE." || \
  echo "    (warn) runner not yet online — check: $KUBECTL -n $RUNNER_NS logs deploy/gitlab-runner"
echo "    Next: onboarding the app (mirror the CI component + Codebase)…"
