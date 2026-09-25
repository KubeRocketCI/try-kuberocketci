#!/usr/bin/env bash
# Post-KRCI Argo CD integration. Requires `make krci` and `make gitlab-up` done first:
# secret ci-gitlab, namespace krci, Argo CD running, GitLab reachable.
# Baseline install is `make argocd` (helm + krci AppProject). This script adds what the
# chart values cannot express:
#   1. GitLab repo SSH credentials (repo-creds) in ns argocd,
#   2. the GitLab host key in argocd-ssh-known-hosts-cm,
#   3. a krci-ci API token stored as the `ci-argocd` integration secret (ns krci).
# Docs: https://docs.kuberocketci.io/docs/operator-guide/cd/argocd-integration
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
GL_NS="${GL_NS:-gitlab}"
WILDCARD="${WILDCARD:-127.0.0.1.nip.io}"
GL_HOST="gitlab.${WILDCARD}"
SSH_PORT="${SSH_PORT:-32222}"
ARGOCD_HOST="argocd.${WILDCARD}"
KUBECTL="kubectl --context $CTX"
HELM="helm --kube-context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ARGOCD_REPO_NAME="${ARGOCD_REPO_NAME:-argo}"
ARGOCD_REPO_URL="${ARGOCD_REPO_URL:-https://argoproj.github.io/argo-helm}"
# Default: the Makefile pin. `make argocd-integrate` passes it explicitly.
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-$(sed -n 's/^ARGOCD_CHART_VERSION *?= *//p' "$HERE/Makefile")}"

echo "==> Waiting for Argo CD server to be ready"
$KUBECTL -n "$ARGOCD_NS" rollout status deploy/argocd-server --timeout=300s

# 1) ---------------------------------------------------------------------------
echo "==> Registering GitLab repo credentials (repo-creds) in ns/$ARGOCD_NS"
# Same SSH key the codebase-operator clones with (ci-gitlab.id_rsa). Argo CD matches
# repo-creds by URL prefix: every repo under the GitLab host over SSH.
KEY="$($KUBECTL -n "$NS" get secret ci-gitlab -o jsonpath='{.data.id_rsa}' | base64 -d)"
if [ -z "$KEY" ]; then echo "!! ci-gitlab/id_rsa not found — run 'make gitlab-up' first" >&2; exit 1; fi
$KUBECTL -n "$ARGOCD_NS" create secret generic gitlab-creds \
  --from-literal=type=git \
  --from-literal=url="ssh://git@${GL_HOST}:${SSH_PORT}/" \
  --from-literal=sshPrivateKey="$KEY" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n "$ARGOCD_NS" label --overwrite secret gitlab-creds \
  "argocd.argoproj.io/secret-type=repo-creds"

# 2) ---------------------------------------------------------------------------
echo "==> Adding the GitLab host key to Argo CD (configs.ssh.extraHosts, via helm)"
# The repo-server verifies the SSH host key. Injected via helm (configs.ssh.extraHosts):
# the chart server-side-applies argocd-ssh-known-hosts-cm and owns .data.ssh_known_hosts;
# any other field manager (kubectl apply/patch) makes the next `make argocd` upgrade fail
# with a field-ownership conflict. Key read from the GitLab pod, labelled for the address
# Argo CD dials: [gitlab.<wildcard>]:32222.
POD="$($KUBECTL -n "$GL_NS" get pods -l app=gitlab -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -z "$POD" ] && POD="$($KUBECTL -n "$GL_NS" get pods -o jsonpath='{.items[0].metadata.name}')"
EXTRA_HOSTS_FILE="$(mktemp)"
$KUBECTL -n "$GL_NS" exec "$POD" -- sh -c '
  for f in /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
    [ -f "$f" ] && awk "{print \$1\" \"\$2}" "$f"
  done' | while read -r type key; do
  [ -n "$type" ] && echo "[${GL_HOST}]:${SSH_PORT} ${type} ${key}"
done > "$EXTRA_HOSTS_FILE"
helm repo add "$ARGOCD_REPO_NAME" "$ARGOCD_REPO_URL" 2>/dev/null || true
$HELM upgrade --install argocd "$ARGOCD_REPO_NAME"/argo-cd --version "$ARGOCD_CHART_VERSION" \
  -n "$ARGOCD_NS" -f "$HERE/values/argo-cd.yaml" \
  --set-file "configs.ssh.extraHosts=$EXTRA_HOSTS_FILE" --wait --timeout 300s
rm -f "$EXTRA_HOSTS_FILE"

# 3) ---------------------------------------------------------------------------
echo "==> Patching the deploy-applicationset-cli task for a plaintext Argo CD server"
# Argo CD serves plain HTTP (server.insecure=true). The stock task's argocd CLI defaults
# to TLS (ARGOCD_OPTS lacks --plaintext): https://argocd-server.argocd.svc:80 ->
# "connection reset". The patch adds --plaintext. `make krci` keeps it (helm 3-way merge
# leaves chart-unchanged fields); same mechanism as the gitlab-set-status fix.
if $KUBECTL -n "$NS" get task deploy-applicationset-cli >/dev/null 2>&1; then
  P="$($KUBECTL -n "$NS" get task deploy-applicationset-cli -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for i,s in enumerate(d['spec']['steps']):
    if s['name']=='wait-for-deploy' and '--plaintext' not in s['script']:
        new=s['script'].replace('--core=false --grpc-web\"','--core=false --grpc-web --plaintext\"')
        print(json.dumps([{'op':'replace','path':f'/spec/steps/{i}/script','value':new}])); break
")"
  [ -n "$P" ] && $KUBECTL -n "$NS" patch task deploy-applicationset-cli --type=json -p "$P"
else
  echo "    (skip) task deploy-applicationset-cli not found — run 'make krci' first"
fi

echo "==> Minting a krci-ci API token and creating the ci-argocd integration secret (ns/$NS)"
# Admin login over the ingress, then a non-expiring token for the krci-ci account
# (accounts.krci-ci: apiKey in values/argo-cd.yaml). KRCI's deploy task and the Portal
# read ci-argocd (label integration-secret) to reach the Argo CD API in-cluster.
ADMIN_PW="$($KUBECTL -n "$ARGOCD_NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
API="http://${ARGOCD_HOST}"
for _ in $(seq 1 30); do
  SESSION="$(curl -fsS -m 10 -X POST "$API/api/v1/session" \
    -H 'Content-Type: application/json' \
    -d "$(printf '{"username":"admin","password":"%s"}' "$ADMIN_PW")" 2>/dev/null \
    | grep -o '"token":"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/')"
  [ -n "${SESSION:-}" ] && break
  echo "    Argo CD API not ready yet; waiting..."; sleep 5
done
[ -z "${SESSION:-}" ] && { echo "!! could not authenticate to Argo CD API at $API" >&2; exit 1; }

CI_TOKEN="$(curl -fsS -m 10 -X POST "$API/api/v1/account/krci-ci/token" \
  -H "Authorization: Bearer $SESSION" -H 'Content-Type: application/json' -d '{}' \
  | grep -o '"token":"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/')"
[ -z "${CI_TOKEN:-}" ] && { echo "!! failed to mint krci-ci token (is accounts.krci-ci=apiKey set?)" >&2; exit 1; }

cat <<EOF | $KUBECTL apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ci-argocd
  namespace: ${NS}
  labels:
    app.edp.epam.com/integration-secret: "true"
    app.edp.epam.com/secret-type: "argocd"
type: Opaque
stringData:
  token: "${CI_TOKEN}"
  url: "http://argocd-server.${ARGOCD_NS}.svc:80"
EOF

echo ""
echo "==> argocd-integrate done."
echo "    Repo creds : secret/gitlab-creds (ns $ARGOCD_NS), repo-creds for ssh://git@${GL_HOST}:${SSH_PORT}/"
echo "    Known host : [${GL_HOST}]:${SSH_PORT} added to argocd-ssh-known-hosts-cm"
echo "    Integration: secret/ci-argocd (ns $NS) -> http://argocd-server.${ARGOCD_NS}.svc:80"
echo "    UI         : http://${ARGOCD_HOST}  (admin; password via 'make status')"
