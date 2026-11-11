#!/usr/bin/env bash
# Optional, after `make e2e` and `make substrate-integrate`: the krci-agent-dispatcher project hook on
# Codebase test-go-app. Every value comes from the cluster:
#   * project: Codebase krci/test-go-app (.spec.gitUrlPath);
#   * GitLab: GitServer krci/gitlab (.spec.gitHost, .spec.httpsPort), Maintainer token in its secret
#     (.spec.nameSshKeySecret, key token), CA in configmap krci/gitlab-ca;
#   * hook URL: https://<host of Ingress krci-agents/krci-agent-dispatcher>/hook; token in secret
#     krci-agents/hook.
# The hook with that exact URL is created or updated: issue and note events only, SSL verification on.
# Other hooks are not changed. A test delivery must reach the dispatcher (/hook 202 in its log).
# Tokens go to curl from a process substitution, never in argv or output.
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
CODEBASE=test-go-app
AGENTS_NS=krci-agents
DISPATCHER=krci-agent-dispatcher
KUBECTL="kubectl --context $CTX"
TMP="$(umask 077; mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL $*" >&2; exit 1; }
jget() { $KUBECTL "$@" 2>/dev/null || true; }
secret_token() { jget -n "$1" get secret "$2" -o jsonpath='{.data.token}' | base64 -d; }

# api METHOD PATH [curl args]: GitLab REST call; prints the body, then the HTTP code on the last line.
api() {
  local method="$1" path="$2"
  shift 2
  curl -sS --noproxy '*' --resolve "$GL_HOST:$GL_PORT:127.0.0.1" --cacert "$TMP/gitlab-ca.crt" \
    -X "$method" -H @<(printf 'PRIVATE-TOKEN: %s\n' "$GL_TOKEN") -H 'Content-Type: application/json' \
    -w '\n%{http_code}' "$@" "https://$GL_HOST:$GL_PORT/api/v4/$path"
}

# call METHOD PATH [curl args]: api with a 2xx check; prints the body.
call() {
  local out code
  out="$(api "$@")" || fail "GitLab $1 $2: curl error"
  code="$(tail -n 1 <<<"$out")"
  case "$code" in 2??) sed '$d' <<<"$out" ;; *) fail "GitLab $1 $2: HTTP $code" ;; esac
}

echo "==> Preconditions"
[ "$(jget -n "$NS" get codebase "$CODEBASE" -o jsonpath='{.status.available}')" = true ] \
  || fail "Codebase $NS/$CODEBASE not available: run make e2e first"
PROJECT="$(jget -n "$NS" get codebase "$CODEBASE" -o jsonpath='{.spec.gitUrlPath}')"
PROJECT="${PROJECT#/}"
GIT_SERVER="$(jget -n "$NS" get codebase "$CODEBASE" -o jsonpath='{.spec.gitServer}')"
GL_HOST="$(jget -n "$NS" get gitserver "$GIT_SERVER" -o jsonpath='{.spec.gitHost}')"
GL_PORT="$(jget -n "$NS" get gitserver "$GIT_SERVER" -o jsonpath='{.spec.httpsPort}')"
GL_SECRET="$(jget -n "$NS" get gitserver "$GIT_SERVER" -o jsonpath='{.spec.nameSshKeySecret}')"
[ -n "$PROJECT" ] && [ -n "$GL_HOST" ] && [ -n "$GL_SECRET" ] || fail "GitServer $NS/$GIT_SERVER incomplete: run make e2e first"
GL_PORT="${GL_PORT:-443}"
jget -n "$NS" get configmap gitlab-ca -o jsonpath='{.data.gitlab-ca\.crt}' >"$TMP/gitlab-ca.crt"
grep -q 'BEGIN CERTIFICATE' "$TMP/gitlab-ca.crt" || fail "no CA (key gitlab-ca.crt) in configmap $NS/gitlab-ca"
HOOK_HOST="$(jget -n "$AGENTS_NS" get ingress "$DISPATCHER" -o jsonpath='{.spec.rules[0].host}')"
[ -n "$HOOK_HOST" ] || fail "Ingress $AGENTS_NS/$DISPATCHER not found: run make substrate-integrate first"
HOOK_URL="https://$HOOK_HOST/hook"
HOOK_TOKEN="$(secret_token "$AGENTS_NS" hook)"
[ -n "$HOOK_TOKEN" ] || fail "no token in secret $AGENTS_NS/hook: run make substrate-integrate first"
GL_TOKEN="$(secret_token "$NS" "$GL_SECRET")"
[ -n "$GL_TOKEN" ] || fail "no token in secret $NS/$GL_SECRET"
TEKTON_HOOK="$(jget -n "$NS" get codebase "$CODEBASE" -o jsonpath='{.status.webHookRef}')"
echo "    project $PROJECT on $GL_HOST; hook URL $HOOK_URL"

echo "==> Hook $HOOK_URL on $PROJECT"
PID="$(call GET "projects/$(jq -rn --arg p "$PROJECT" '$p | @uri')" | jq -r '.id')"
HID="$(call GET "projects/$PID/hooks?per_page=100" | jq -r --arg u "$HOOK_URL" 'first(.[] | select(.url == $u) | .id) // empty')"
[ -z "$HID" ] || [ "$HID" != "$TEKTON_HOOK" ] || fail "hook $HID is the Tekton hook of Codebase $CODEBASE"
jq -n --arg u "$HOOK_URL" --rawfile t <(printf '%s' "$HOOK_TOKEN") '{
  url: $u, token: $t, enable_ssl_verification: true,
  issues_events: true, note_events: true,
  push_events: false, merge_requests_events: false, tag_push_events: false, pipeline_events: false,
  job_events: false, wiki_page_events: false, confidential_issues_events: false,
  confidential_note_events: false, deployment_events: false, releases_events: false,
  feature_flag_events: false, emoji_events: false, resource_access_token_events: false}' >"$TMP/hook.json"
if [ -n "$HID" ]; then
  call PUT "projects/$PID/hooks/$HID" --data-binary @"$TMP/hook.json" >/dev/null
  echo "    hook $HID updated"
else
  HID="$(call POST "projects/$PID/hooks" --data-binary @"$TMP/hook.json" | jq -r '.id')"
  echo "    hook $HID created"
fi

echo "==> Test delivery"
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CODE="$(api POST "projects/$PID/hooks/$HID/test/push_events" | tail -n 1)"
case "$CODE" in 2??) ;; *) fail "test delivery: GitLab HTTP $CODE" ;; esac
for _ in 1 2 3 4 5 6; do
  if jget -n "$AGENTS_NS" logs "deploy/$DISPATCHER" --since-time="$SINCE" \
    | jq -e -R 'fromjson? | select(.httpRequest.path == "/hook" and .httpResponse.status == 202)' >/dev/null; then
    echo "    hook $HID ready: GitLab $CODE, dispatcher /hook 202"
    exit 0
  fi
  sleep 2
done
fail "test delivery: GitLab $CODE, but no /hook 202 in the $DISPATCHER log"
