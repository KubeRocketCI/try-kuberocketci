#!/usr/bin/env bash
# GitLab Runner (Kubernetes executor) for the KubeRocketCI GitLab CI path. Pairs with
# scripts/gitlab-ci-onboard.sh (component mirror + app) and scripts/e2e-gitlabci.sh.
#
# Codebase spec.ciTool=gitlab: the codebase-operator skips the Tekton EventListener and
# pushes a .gitlab-ci.yml; the jobs need a runner, which KubeRocketCI does not bundle.
#
# Steps (idempotent):
#   1. namespace + GitLab CA secret the runner trusts (from secret gitlab-tls),
#   2. mint a runner AUTH token (instance runner, created as root via
#      scripts/gitlab-rails/runner-token.rb),
#   3. helm install gitlab/gitlab-runner with that token (values/gitlab-runner.yaml),
#   4. wait for the runner pod Ready and the runner to report online.
# No QEMU/binfmt: the pipeline builds native arm64 (docs/gitlab-ci.md).
set -euo pipefail

CTX="${CTX:-kind-krci}"
GL_NS="gitlab"
RUNNER_NS="${RUNNER_NS:-gitlab-runner}"
WILDCARD="${WILDCARD:-127.0.0.1.nip.io}"
GL_HOST="gitlab.${WILDCARD}"
CHART_VERSION="${GITLAB_RUNNER_CHART_VERSION:-0.94.3}"
KUBECTL="kubectl --context $CTX"
HELM="helm --kube-context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

RUNNER_DESC="krci-kubernetes"
. "$HERE/scripts/lib/gitlab.sh"

echo "==> Namespace $RUNNER_NS + GitLab CA secret (gitlab-runner-certs)"
$KUBECTL get ns "$RUNNER_NS" >/dev/null 2>&1 || $KUBECTL create ns "$RUNNER_NS"
# Runner CA trust: the secret key must be "<host>.crt". gitlab-tls is self-signed with
# CA:TRUE, so its tls.crt is the CA.
$KUBECTL -n $GL_NS get secret gitlab-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/gitlab-runner-ca.crt
$KUBECTL -n "$RUNNER_NS" create secret generic gitlab-runner-certs \
  --from-file="${GL_HOST}.crt=/tmp/gitlab-runner-ca.crt" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
rm -f /tmp/gitlab-runner-ca.crt

echo "==> Minting a runner authentication token (instance runner; idempotent)"
# Registration tokens are disabled: create a runner object, use its auth token
# (glrt-…). Prior '$RUNNER_DESC' instance runners are deleted first (re-run safe).
RUNNER_TOKEN="$(gl_rails runner-token.rb description="$RUNNER_DESC" | json_get token)"
echo "    runner token: ${RUNNER_TOKEN:0:8}…"

echo "==> Installing gitlab/gitlab-runner (chart $CHART_VERSION)"
helm repo add gitlab https://charts.gitlab.io >/dev/null 2>&1 || true
helm repo update gitlab >/dev/null 2>&1
$HELM upgrade --install gitlab-runner gitlab/gitlab-runner \
  --version "$CHART_VERSION" -n "$RUNNER_NS" \
  -f "$HERE/values/gitlab-runner.yaml" \
  --set runnerToken="$RUNNER_TOKEN" \
  --wait --timeout 300s

# Never add `tonistiigi/binfmt --install amd64` here: it replaces Rosetta with
# qemu-x86_64 in the shared VM kernel and crashes emulated Go binaries. The pipeline builds
# native arm64. See docs/gitlab-ci.md.

echo "==> Waiting for the runner to report online"
ONLINE="$(gl_rails runner-online.rb description="$RUNNER_DESC" timeout_seconds=150 | json_get online)"

echo ""
echo "==> gitlab-runner done."
$KUBECTL -n "$RUNNER_NS" get pods
[ "$ONLINE" = true ] && echo "    Runner '$RUNNER_DESC' is ONLINE." || \
  echo "    (warn) runner not yet online — check: $KUBECTL -n $RUNNER_NS logs deploy/gitlab-runner"
echo "    Next: onboarding the app (mirror the CI component + Codebase)…"
