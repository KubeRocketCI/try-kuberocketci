#!/usr/bin/env bash
# KubeRocketCI GitLab users. Runs from scripts/gitlab-up.sh after group $NS exists; re-run: make gitlab-users.
#   - Administrator (root): name + avatar. Removes root's 'krci' token and SSH key from earlier layouts.
#   - KRCI CI/CD (krci-ci): Maintainer on group $NS (Git Server prerequisites: SSH key, api token,
#     Maintainer or Owner). Secret $NS/ci-gitlab: token, username, id_rsa, secretString.
# Re-run replaces the tokens; the SSH key and webhook secret are kept.
# Other platforms onboard their own users with onboard_gitlab_user (e.g. scripts/substrate-integrate.sh).
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
KUBECTL="kubectl --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/lib/gitlab.sh"

ensure_gitlab_admin_profile() {
  local res
  echo "==> Administrator (root): profile"
  res="$(gl_rails user.rb username=root name="Administrator" avatar=@"$HERE/assets/gitlab-admin-avatar.png" \
    revoke_tokens=krci remove_keys=krci)"
  echo "    $(printf '%s' "$res" | json_get summary)"
}

onboard_krci_ci() {
  local dir="$GL_TMP/ci-gitlab" key="$GL_TMP/ci-gitlab-key"
  echo "==> KRCI CI/CD (krci-ci): Maintainer on group $NS -> secret $NS/ci-gitlab"
  mkdir "$dir"
  # Argo CD repo-creds hold a copy of id_rsa: reuse it when valid.
  $KUBECTL -n "$NS" get secret ci-gitlab -o jsonpath='{.data.id_rsa}' 2>/dev/null | base64 -d >"$key" 2>/dev/null || true
  chmod 600 "$key"
  if [ -s "$key" ] && ssh-keygen -y -f "$key" >"$key.pub" 2>/dev/null; then
    echo "    SSH key reused from secret ci-gitlab"
  else
    rm -f "$key" "$key.pub"
    ssh-keygen -q -t ed25519 -N "" -C "krci-ci@local" -f "$key"
  fi
  cp "$key" "$dir/id_rsa"

  onboard_gitlab_user username=krci-ci name="KRCI CI/CD" avatar=@"$HERE/assets/krci-ci-avatar.png" \
    group="$NS" access=maintainer token_name=krci scopes=api expires_days=365 \
    ssh_title=krci ssh_pub="$(cat "$key.pub")" >"$dir/token"
  printf 'krci-ci' >"$dir/username"
  # The operator does not update the token of existing project hooks: keep the webhook secret.
  $KUBECTL -n "$NS" get secret ci-gitlab -o jsonpath='{.data.secretString}' 2>/dev/null | base64 -d >"$dir/secretString" 2>/dev/null || true
  [ -s "$dir/secretString" ] || openssl rand -hex 20 | tr -d '\n' >"$dir/secretString"
  apply_secret "$NS" ci-gitlab "$dir"
}

# Order: root's legacy 'krci' SSH key can equal the reused ci-gitlab key; remove it before krci-ci gets it.
ensure_gitlab_admin_profile
onboard_krci_ci
