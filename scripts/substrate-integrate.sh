#!/usr/bin/env bash
# Optional post-KRCI Substrate integration, not part of `make testbed`. Requires `make substrate`,
# the Substrate namespace $SUBSTRATE_NS and `make gitlab-up` (group krci exists).
# Re-run after `make substrate`.
#   * egress gateway upstream TLS: image roots + the CA in SUBSTRATE_EGRESS_CA (<ns>/<configmap>, key
#     gitlab-ca.crt; default krci/gitlab-ca; empty: skipped). Upstream v1.0.0 has no setting for it.
#     manifests/substrate-egress-upstream-ca.yaml, server-side apply under field manager krci-testbed.
#   * GitLab user krci-agent (KRCI Agent): Developer on group krci (clone, push to unprotected
#     branches, merge requests, notes, labels). Token krci-agent: api + write_repository, 30 days;
#     replaced on every run.
#   * secret $SUBSTRATE_NS/gitlab: token; basic = base64("oauth2:<token>") (Authorization: Basic
#     value for git over HTTPS).
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
SUBSTRATE_NS="${SUBSTRATE_NS:-krci-agents}"
SUBSTRATE_EGRESS_CA="${SUBSTRATE_EGRESS_CA-krci/gitlab-ca}"
FIELD_MANAGER=krci-testbed
KUBECTL="kubectl --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
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

echo "==> Egress gateway upstream CA"
egress_upstream_ca

$KUBECTL get namespace "$SUBSTRATE_NS" >/dev/null 2>&1 \
  || { echo "FAIL namespace $SUBSTRATE_NS not found: install Substrate first" >&2; exit 1; }

echo "==> KRCI Agent (krci-agent): Developer on group $NS -> secret $SUBSTRATE_NS/gitlab"
DIR="$GL_TMP/gitlab"
mkdir "$DIR"
onboard_gitlab_user username=krci-agent name="KRCI Agent" avatar=@"$HERE/assets/krci-agent-avatar.png" \
  group="$NS" access=developer token_name=krci-agent scopes=api,write_repository expires_days=30 >"$DIR/token"
printf 'oauth2:%s' "$(cat "$DIR/token")" | base64 | tr -d '\n' >"$DIR/basic"
apply_secret "$SUBSTRATE_NS" gitlab "$DIR"
