#!/usr/bin/env bash
# Optional post-KRCI Substrate integration, not part of `make testbed`: the landing zone krci-agents
# for agent workloads. Requires `make substrate` and `make gitlab-up` (group krci exists).
# Re-run after `make substrate`. No application names here: the application layer adds its own
# API access and grants.
#   * egress gateway upstream TLS: image roots + the CA in SUBSTRATE_EGRESS_CA (<ns>/<configmap>, key
#     gitlab-ca.crt; default krci/gitlab-ca; empty: skipped). Upstream v1.0.0 has no setting for it.
#     manifests/substrate-egress-upstream-ca.yaml, server-side apply under field manager krci-testbed.
#   * namespace + atespace krci-agents, WorkerPool krci-agents/workers (ateworker-gvisor at the
#     installed Substrate version): manifests/substrate-landing.yaml.
#   * credential provider namespace policy krci-agents -> [krci-agents]:
#     manifests/substrate-namespace-policy.yaml.
#   * GitLab user krci-agent (KRCI Agent): Developer on group krci (clone, push to unprotected
#     branches, merge requests, notes, labels). Token krci-agent: api + write_repository, 30 days;
#     replaced on every run.
#   * secret krci-agents/gitlab: token; basic = base64("oauth2:<token>") (Authorization: Basic
#     value for git over HTTPS).
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
SUBSTRATE_VERSION="${SUBSTRATE_VERSION:?SUBSTRATE_VERSION is required}"
AGENTS_NS=krci-agents
SUBSTRATE_EGRESS_CA="${SUBSTRATE_EGRESS_CA-krci/gitlab-ca}"
FIELD_MANAGER=krci-testbed
KUBECTL="kubectl --context $CTX"
KUBECTL_ATE="kubectl ate --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PATH="$HERE/.cache/substrate/$SUBSTRATE_VERSION/bin:$PATH"
. "$HERE/scripts/lib/gitlab.sh"

egress_upstream_ca() {
  local src="$SUBSTRATE_EGRESS_CA" dir="$GL_TMP/egress-ca" img hash
  if [ -z "$src" ]; then echo "    (skip) SUBSTRATE_EGRESS_CA is empty"; return 0; fi
  img="$($KUBECTL -n ate-system get deploy atenet-egress \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="envoy")].image}' 2>/dev/null || true)"
  [ -n "$img" ] || { echo "FAIL ate-system/atenet-egress not found: run make substrate first" >&2; exit 1; }
  mkdir "$dir"
  $KUBECTL -n "${src%/*}" get configmap "${src#*/}" -o jsonpath='{.data.gitlab-ca\.crt}' >"$dir/ca.crt" 2>/dev/null || true
  grep -q 'BEGIN CERTIFICATE' "$dir/ca.crt" || { echo "FAIL no CA (key gitlab-ca.crt) in configmap $src" >&2; exit 1; }
  hash="$(shasum -a 256 "$dir/ca.crt" | cut -c1-64)"
  $KUBECTL -n ate-system create configmap egress-upstream-ca --from-file=ca.crt="$dir/ca.crt" --dry-run=client -o yaml \
    | $KUBECTL apply --server-side --field-manager="$FIELD_MANAGER" -f - >/dev/null
  sed -e "s|@IMAGE@|$img|" -e "s|@HASH@|$hash|" "$HERE/manifests/substrate-egress-upstream-ca.yaml" \
    | $KUBECTL apply --server-side --field-manager="$FIELD_MANAGER" -f - >/dev/null
  $KUBECTL -n ate-system rollout status deploy/atenet-egress --timeout=180s >/dev/null
  echo "    egress gateway trusts $src (sha256 ${hash:0:12})"
}

landing_zone() {
  local atelet worker hash policy="$HERE/manifests/substrate-namespace-policy.yaml"
  command -v kubectl-ate >/dev/null || { echo "FAIL kubectl-ate $SUBSTRATE_VERSION not found: run make substrate first" >&2; exit 1; }
  atelet="$($KUBECTL -n ate-system get daemonset atelet \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="atelet")].image}' 2>/dev/null || true)"
  [ -n "$atelet" ] || { echo "FAIL ate-system/atelet not found: run make substrate first" >&2; exit 1; }
  atelet="${atelet%@*}"
  worker="${atelet%/*}/ateworker-gvisor:${atelet##*:}"
  sed -e "s|@WORKER_IMAGE@|$worker|" "$HERE/manifests/substrate-landing.yaml" \
    | $KUBECTL apply --server-side --field-manager="$FIELD_MANAGER" -f - >/dev/null
  $KUBECTL -n "$AGENTS_NS" wait workerpool/workers --for=jsonpath='{.status.readyReplicas}'=1 --timeout=300s >/dev/null
  echo "    namespace $AGENTS_NS, WorkerPool workers ready ($worker)"
  if $KUBECTL_ATE get atespace "$AGENTS_NS" >/dev/null 2>&1; then
    echo "    atespace $AGENTS_NS present"
  else
    $KUBECTL_ATE create atespace "$AGENTS_NS" >/dev/null 2>&1
    echo "    atespace $AGENTS_NS created"
  fi
  hash="$(shasum -a 256 "$policy" | cut -c1-64)"
  sed -e "s|@POLICY_HASH@|$hash|" "$policy" \
    | $KUBECTL apply --server-side --force-conflicts --field-manager="$FIELD_MANAGER" -f - >/dev/null
  $KUBECTL -n ate-system rollout status deployment/k8s-credential-provider --timeout=120s >/dev/null
  echo "    namespace policy $AGENTS_NS -> [$AGENTS_NS] (sha256 ${hash:0:12})"
}

echo "==> Egress gateway upstream CA"
egress_upstream_ca

echo "==> Landing zone $AGENTS_NS"
landing_zone

echo "==> KRCI Agent (krci-agent): Developer on group $NS -> secret $AGENTS_NS/gitlab"
DIR="$GL_TMP/gitlab"
mkdir "$DIR"
onboard_gitlab_user username=krci-agent name="KRCI Agent" avatar=@"$HERE/assets/krci-agent-avatar.png" \
  group="$NS" access=developer token_name=krci-agent scopes=api,write_repository expires_days=30 >"$DIR/token"
printf 'oauth2:%s' "$(cat "$DIR/token")" | base64 | tr -d '\n' >"$DIR/basic"
apply_secret "$AGENTS_NS" gitlab "$DIR"
