#!/usr/bin/env bash
# Optional post-KRCI Substrate integration, not part of `make testbed`. Requires the Substrate
# namespace $SUBSTRATE_NS and `make gitlab-up` (group krci exists).
#   * GitLab user krci-agent (KRCI Agent): Developer on group krci (clone, push to unprotected
#     branches, merge requests, notes, labels). Token krci-agent: api + write_repository, 30 days;
#     replaced on every run.
#   * secret $SUBSTRATE_NS/gitlab: token; basic = base64("oauth2:<token>") (Authorization: Basic
#     value for git over HTTPS).
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
SUBSTRATE_NS="${SUBSTRATE_NS:-krci-agents}"
KUBECTL="kubectl --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/lib/gitlab.sh"

$KUBECTL get namespace "$SUBSTRATE_NS" >/dev/null 2>&1 \
  || { echo "FAIL namespace $SUBSTRATE_NS not found: install Substrate first" >&2; exit 1; }

echo "==> KRCI Agent (krci-agent): Developer on group $NS -> secret $SUBSTRATE_NS/gitlab"
DIR="$GL_TMP/gitlab"
mkdir "$DIR"
onboard_gitlab_user username=krci-agent name="KRCI Agent" avatar=@"$HERE/assets/krci-agent-avatar.png" \
  group="$NS" access=developer token_name=krci-agent scopes=api,write_repository expires_days=30 >"$DIR/token"
printf 'oauth2:%s' "$(cat "$DIR/token")" | base64 | tr -d '\n' >"$DIR/basic"
apply_secret "$SUBSTRATE_NS" gitlab "$DIR"
