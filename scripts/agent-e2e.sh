#!/usr/bin/env bash
# End-to-end validation of the issue agent on Codebase test-go-app, after `make substrate-integrate` and
# `make substrate-hook`. Phases:
#   1. open an issue with the trigger label krci-agent,
#   2. wait for the turn 1 reply; assert its turn marker has exit 0,
#   3. mark the agent's merge request ready and merge it,
#   4. assert the issue is krci::agent::done and its actor is deleted.
#
# Exit 0 = PASS, non-zero = FAIL. Values come from the cluster as in substrate-hook.sh; the token goes to curl
# from a process substitution, never in argv or output.
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
SUBSTRATE_VERSION="${SUBSTRATE_VERSION:?SUBSTRATE_VERSION is required}"
TURN_TIMEOUT="${TURN_TIMEOUT:-1200}"
CODEBASE=test-go-app
AGENTS_NS=krci-agents
BOT=krci-agent
KUBECTL="kubectl --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ATE="$HERE/.cache/substrate/$SUBSTRATE_VERSION/bin/kubectl-ate"
TMP="$(umask 077; mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say()  { echo "==> $*"; }
info() { echo "    $*"; }
fail() { echo "AGENT-E2E: FAIL — $*"; exit 1; }
jget() { $KUBECTL "$@" 2>/dev/null || true; }

# call METHOD PATH [JSON]: GitLab REST call with a 2xx check; prints the body.
call() {
  local out code
  out="$(curl -sS --noproxy '*' --resolve "$GL_HOST:$GL_PORT:127.0.0.1" --cacert "$TMP/gitlab-ca.crt" \
    -X "$1" -H @<(printf 'PRIVATE-TOKEN: %s\n' "$GL_TOKEN") -H 'Content-Type: application/json' \
    ${3:+--data "$3"} -w '\n%{http_code}' "https://$GL_HOST:$GL_PORT/api/v4/$2")" || fail "GitLab $1 $2: curl error"
  code="$(tail -n 1 <<<"$out")"
  case "$code" in 2??) sed '$d' <<<"$out" ;; *) fail "GitLab $1 $2: HTTP $code" ;; esac
}

# wait_for SECONDS DESCRIPTION COMMAND...: run COMMAND every 10 s until it succeeds.
wait_for() {
  local end=$(( $(date +%s) + $1 )) what="$2"
  shift 2
  until "$@"; do
    [ "$(date +%s)" -lt "$end" ] || fail "timeout: $what"
    sleep 10
  done
}

say "Preconditions"
[ -x "$ATE" ] || fail "$ATE missing: run make substrate first"
[ "$(jget -n "$NS" get codebase "$CODEBASE" -o jsonpath='{.status.available}')" = true ] \
  || fail "Codebase $NS/$CODEBASE not available: run make e2e first"
[ "$(jget -n "$AGENTS_NS" get deploy krci-agent-dispatcher -o jsonpath='{.status.readyReplicas}')" = 1 ] \
  || fail "krci-agent-dispatcher not ready: run make substrate-integrate first"
PROJECT="$(jget -n "$NS" get codebase "$CODEBASE" -o jsonpath='{.spec.gitUrlPath}')"
PROJECT="${PROJECT#/}"
GIT_SERVER="$(jget -n "$NS" get codebase "$CODEBASE" -o jsonpath='{.spec.gitServer}')"
GL_HOST="$(jget -n "$NS" get gitserver "$GIT_SERVER" -o jsonpath='{.spec.gitHost}')"
GL_PORT="$(jget -n "$NS" get gitserver "$GIT_SERVER" -o jsonpath='{.spec.httpsPort}')"
GL_PORT="${GL_PORT:-443}"
GL_SECRET="$(jget -n "$NS" get gitserver "$GIT_SERVER" -o jsonpath='{.spec.nameSshKeySecret}')"
GL_TOKEN="$(jget -n "$NS" get secret "$GL_SECRET" -o jsonpath='{.data.token}' | base64 -d)"
[ -n "$PROJECT" ] && [ -n "$GL_HOST" ] && [ -n "$GL_TOKEN" ] || fail "GitServer $NS/$GIT_SERVER incomplete"
jget -n "$NS" get configmap gitlab-ca -o jsonpath='{.data.gitlab-ca\.crt}' >"$TMP/gitlab-ca.crt"
PID="$(call GET "projects/$(jq -rn --arg p "$PROJECT" '$p | @uri')" | jq -r .id)"

say "Issue"
PKG="e2e$(date +%s)"
IID="$(call POST "projects/$PID/issues" "$(jq -n --arg p "$PKG" \
  '{title: "Add the \($p) package", labels: "krci-agent",
    description: "Add a package `\($p)` with `func Ping() string` returning `pong`, with a table test."}')" | jq -r .iid)"
info "$PROJECT#$IID, package $PKG"

say "Turn 1"
marker() {
  call GET "projects/$PID/issues/$IID/notes?sort=asc&per_page=100" \
    | jq -r --arg bot "$BOT" '[.[] | select(.author.username == $bot) | .body
        | capture("krci-agent-turn s=[^ ]+ n=1 exit=(?<rc>[0-9]+) ") | .rc] | last // empty'
}
replied() { [ -n "$(marker)" ]; }
wait_for "$TURN_TIMEOUT" "turn 1 reply on #$IID" replied
[ "$(marker)" = 0 ] || fail "turn 1 on #$IID ended with exit $(marker)"
info "turn 1 exit 0"

say "Merge request"
MR="$(call GET "projects/$PID/merge_requests?state=opened&source_branch=agent/issue-$IID" | jq -r '.[0].iid // empty')"
[ -n "$MR" ] || fail "no open merge request from agent/issue-$IID"
call PUT "projects/$PID/merge_requests/$MR" '{"title": "Resolve \"Add the '"$PKG"' package\""}' >/dev/null
mergeable() { [ "$(call GET "projects/$PID/merge_requests/$MR" | jq -r .detailed_merge_status)" = mergeable ]; }
wait_for 180 "!$MR mergeable" mergeable
call PUT "projects/$PID/merge_requests/$MR/merge" '{"should_remove_source_branch": true}' >/dev/null
info "!$MR merged"

say "Stop"
done_label() { call GET "projects/$PID/issues/$IID" | jq -e '.labels | index("krci::agent::done")' >/dev/null; }
wait_for 180 "#$IID labelled krci::agent::done" done_label
actor_gone() { ! "$ATE" --context "$CTX" get actors -a "$AGENTS_NS" 2>/dev/null | awk '{print $2}' | grep -qx "issue-$PID-$IID"; }
wait_for 180 "actor issue-$PID-$IID deleted" actor_gone

echo "AGENT-E2E: PASS — $PROJECT#$IID: turn 1, !$MR merged, issue done, actor deleted"
