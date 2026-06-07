#!/usr/bin/env bash
# Validate the GitLab CI path the way scripts/e2e.sh validates the Tekton path: the
# Codebase java-gitlabci-app has ciTool=gitlab, so its CI runs in GitLab CI (on the
# in-cluster GitLab Runner) instead of Tekton. Flow: open an MR -> the REVIEW pipeline
# runs (test/build/lint/sonar/dockerbuild-verify) -> merge -> the BUILD pipeline runs
# (… + buildkit image build & push to the GitLab registry + git-tag). PASS = both
# pipelines fully green AND no Tekton PipelineRun was created for this codebase.
#
# Prereqs: make gitlab-ci (sets up the runner, the mirrored ci-java17-mvn component,
# the seeded app, the CI variables and the Codebase).
set -euo pipefail

CTX="${CTX:-kind-krci}"; NS="${NS:-krci}"; GL_NS="gitlab"
CODEBASE="java-gitlabci-app"; PROJECT="krci/${CODEBASE}"; PROJECT_ENC="krci%2F${CODEBASE}"
BRANCH="main"
KUBECTL="kubectl --context $CTX"

say(){ echo "==> $*"; }; info(){ echo "    $*"; }; fail(){ echo "E2E-GITLABCI: FAIL — $*"; exit 1; }

GLPOD="$($KUBECTL -n $GL_NS get pod -l app=gitlab -o jsonpath='{.items[0].metadata.name}')"
PAT="$($KUBECTL -n $NS get secret ci-gitlab -o jsonpath='{.data.token}' | base64 -d)"
# Run a GitLab REST call from inside the gitlab pod (self-signed https://localhost).
gl(){ local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then $KUBECTL -n $GL_NS exec "$GLPOD" -- curl -sk -X "$m" -H "PRIVATE-TOKEN: $PAT" -H 'Content-Type: application/json' -d "$b" "https://localhost/api/v4/$p"
  else $KUBECTL -n $GL_NS exec "$GLPOD" -- curl -sk -X "$m" -H "PRIVATE-TOKEN: $PAT" "https://localhost/api/v4/$p"; fi; }

PID="$(gl GET "projects/$PROJECT_ENC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')"
[ -n "$PID" ] || fail "project $PROJECT not found — run 'make gitlab-ci' first"

# Wait for a pipeline to finish; echo its final status.
wait_pipeline(){ local pip="$1" t="${2:-90}" st
  for _ in $(seq 1 "$t"); do
    st="$(gl GET "projects/$PID/pipelines/$pip" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))')"
    case "$st" in success|failed|canceled|skipped) echo "$st"; return 0;; esac
    sleep 10
  done; echo "timeout"; }

# Print each job + status; fail unless the pipeline is fully green.
assert_green(){ local pip="$1" what="$2" st
  say "$what pipeline #$pip — per-job result"
  gl GET "projects/$PID/pipelines/$pip/jobs?per_page=100" | python3 -c '
import json,sys
for j in sorted(json.load(sys.stdin),key=lambda x:(x["stage"],x["name"])):
    print("    %-9s %-9s %s"%(j["status"],j["stage"],j["name"]))'
  st="$(gl GET "projects/$PID/pipelines/$pip" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))')"
  [ "$st" = success ] || fail "$what pipeline #$pip is '$st' (not all jobs green)"
  info "$what pipeline #$pip: GREEN"; }

# ── preflight: this codebase really is a GitLab-CI codebase, not Tekton ──────────
say "Preflight: $CODEBASE is a GitLab CI codebase (ciTool=gitlab, no Tekton EventListener)"
CIT="$($KUBECTL -n $NS get codebase $CODEBASE -o jsonpath='{.spec.ciTool}' 2>/dev/null || true)"
[ "$CIT" = gitlab ] || fail "codebase $CODEBASE has ciTool='$CIT' (expected gitlab)"
gl GET "projects/$PROJECT_ENC/repository/files/.gitlab-ci.yml?ref=$BRANCH" | grep -q '"file_name"' || fail ".gitlab-ci.yml missing in $PROJECT"
HOOKS="$(gl GET "projects/$PROJECT_ENC/hooks" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(-1)')"
[ "$HOOKS" = 0 ] || info "(note) project has $HOOKS webhook(s); GitLab CI does not need one"
info "ciTool=gitlab, .gitlab-ci.yml present, webhooks=$HOOKS"

# ── review: open an MR -> merge_request_event pipeline ───────────────────────────
BR="ci-gitlabci-$(date +%s)"
say "Opening a merge request ($BR) -> review pipeline"
gl POST "projects/$PID/repository/branches?branch=$BR&ref=$BRANCH" >/dev/null
gl POST "projects/$PID/repository/commits" \
  "$(printf '{"branch":"%s","commit_message":"e2e-gitlabci","actions":[{"action":"create","file_path":"e2e-%s.txt","content":"x"}]}' "$BR" "$BR")" >/dev/null
MR_IID="$(gl POST "projects/$PID/merge_requests" \
  "$(printf '{"source_branch":"%s","target_branch":"%s","title":"e2e-gitlabci %s","remove_source_branch":true}' "$BR" "$BRANCH" "$BR")" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("iid",""))')"
[ -n "$MR_IID" ] || fail "could not open merge request"
info "merge request !$MR_IID opened"

say "Waiting for the review (merge_request_event) pipeline"
REVIEW=""
for _ in $(seq 1 30); do
  REVIEW="$(gl GET "projects/$PID/merge_requests/$MR_IID/pipelines" | python3 -c 'import json,sys
d=json.load(sys.stdin); print(d[0]["id"] if isinstance(d,list) and d else "")')"
  [ -n "$REVIEW" ] && break; sleep 4
done
[ -n "$REVIEW" ] || fail "no review pipeline was created for MR !$MR_IID (GitLab did not start a merge_request pipeline)"
info "review pipeline #$REVIEW"
RS="$(wait_pipeline "$REVIEW" 90)"; info "review finished: $RS"
assert_green "$REVIEW" "review"

# ── build: merge the MR -> push pipeline on the protected default branch ─────────
say "Merging merge request !$MR_IID -> build pipeline"
before_pipe="$(gl GET "projects/$PID/pipelines?ref=$BRANCH&per_page=1" | python3 -c 'import json,sys
d=json.load(sys.stdin); print(d[0]["id"] if d else 0)')"
merged=""
for _ in $(seq 1 24); do
  ms="$(gl GET "projects/$PID/merge_requests/$MR_IID" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("detailed_merge_status") or d.get("merge_status",""))')"
  case "$ms" in mergeable|can_be_merged)
    [ "$(gl PUT "projects/$PID/merge_requests/$MR_IID/merge" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("state",""))' 2>/dev/null||true)" = merged ] && { merged=1; break; };; esac
  sleep 5
done
[ -n "$merged" ] || fail "could not merge MR (last status='$ms')"
info "merge request !$MR_IID merged"

say "Waiting for the build pipeline on $BRANCH"
BUILD=""
for _ in $(seq 1 30); do
  BUILD="$(gl GET "projects/$PID/pipelines?ref=$BRANCH&per_page=1" | python3 -c 'import json,sys
d=json.load(sys.stdin); print(d[0]["id"] if d else 0)')"
  [ -n "$BUILD" ] && [ "$BUILD" != "$before_pipe" ] && [ "$BUILD" != 0 ] && break
  BUILD=""; sleep 5
done
[ -n "$BUILD" ] || fail "no build pipeline was triggered by the merge"
info "build pipeline #$BUILD"
BS="$(wait_pipeline "$BUILD" 150)"; info "build finished: $BS"
assert_green "$BUILD" "build"

# ── report registry image + tag, and prove Tekton did NOT run ────────────────────
say "GitLab Container Registry — image published by the build pipeline"
gl GET "projects/$PID/registry/repositories?tags=true" | python3 -c '
import json,sys
d=json.load(sys.stdin)
[print("    image:",r["path"],"tags=",[t["name"] for t in r.get("tags",[])]) for r in d] or print("    (none)")'
say "Git tags created by git-tag"
gl GET "projects/$PID/repository/tags?per_page=3" | python3 -c 'import json,sys;[print("    tag:",t["name"]) for t in json.load(sys.stdin)]'

say "Confirming no Tekton PipelineRun ran for $CODEBASE (CI was GitLab CI, not Tekton)"
PRUNS="$($KUBECTL -n $NS get pipelinerun -l app.edp.epam.com/codebase=$CODEBASE -o name 2>/dev/null | wc -l | tr -d ' ')"
[ "$PRUNS" = 0 ] || fail "found $PRUNS Tekton PipelineRun(s) for $CODEBASE — expected 0"
info "Tekton PipelineRuns for $CODEBASE: 0"

echo
echo "E2E-GITLABCI: PASS — review + build pipelines fully green on the GitLab Runner; image"
echo "              pushed to the GitLab registry; tag created; zero Tekton PipelineRuns."
exit 0
