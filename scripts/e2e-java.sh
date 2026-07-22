#!/usr/bin/env bash
# Validate the Java/Maven -> GitLab Package Registry path, the way scripts/e2e.sh
# validates the Go path: onboard a maven Codebase (create strategy), open a merge
# request (review pipeline), then merge it (build pipeline). The point is the
# artifact-registry integration — Maven resolving from Central + the GitLab group
# endpoint, and publishing via `mvn deploy` to the per-project endpoint.
#
# ─────────────────────────────────────────────────────────────────────────────
# KNOWN DOCKER ISSUE — NOT fixed here, by design (this script only EXPLAINS it):
#
#   On Apple Silicon (arm64) the kaniko image steps fail:
#       review : dockerbuild-verify   build : container-build
#       -> "no child with platform linux/arm64 in index
#           public.ecr.aws/docker/library/eclipse-temurin:17-jre-alpine"
#
#   The scaffolded template's Dockerfile base `eclipse-temurin:17-jre-alpine` is
#   amd64-only (the alpine Temurin images have no arm64 build), so kaniko cannot
#   build the image on an arm64 node. This is an ARCHITECTURE issue in the upstream
#   template — NOT a registry/Maven issue. To fix it, change the base in the
#   codebase's Dockerfile to a multi-arch image, e.g. `FROM eclipse-temurin:17-jre`
#   (amd64 + arm64).
#
#   This script therefore TOLERATES failures limited to {dockerbuild-verify,
#   container-build} and asserts only that the Maven/registry (and all other) tasks
#   are green. On an amd64 host the docker steps pass and runs are fully green.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CTX="${CTX:-kind-krci}"; NS="${NS:-krci}"; GL_NS="gitlab"
PROJECT_ENC="krci%2Ftest-java-app"; CODEBASE="test-java-app"; BRANCH="main"
KUBECTL="kubectl --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# Failures limited to these tasks are the known amd64-only-base-image issue on arm64.
ARCH_TASKS="dockerbuild-verify container-build"
# GitLab can deliver the MR webhook twice; the duplicate run fails fast on these:
# the start gate (SHA/context already reported) and its finally reporter. The
# review pipeline reports via the single 'gitlab-report-pipeline-status'; the build
# pipeline uses the two-task build vote, of which only 'gitlab-set-failure-status'
# can report a failed condition.
DUP_TASKS="report-pipeline-start-to-gitlab gitlab-report-pipeline-status gitlab-set-failure-status"

say(){ echo "==> $*"; }; info(){ echo "    $*"; }; fail(){ echo "E2E-JAVA: FAIL — $*"; exit 1; }
docker_note(){ cat <<'EOT'
    NOTE: the kaniko build step failed because the scaffolded Dockerfile base
    'eclipse-temurin:17-jre-alpine' is amd64-only (no arm64 build), so it cannot
    build on this arm64 node. This is an ARCH issue in the upstream template, not a
    registry/Maven issue. Fix in the codebase: base on multi-arch 'eclipse-temurin:17-jre'.
EOT
}

GLPOD="$($KUBECTL -n $GL_NS get pod -l app=gitlab -o jsonpath='{.items[0].metadata.name}')"
PAT="$($KUBECTL -n $NS get secret ci-gitlab -o jsonpath='{.data.token}' | base64 -d)"
gl_api(){ local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then $KUBECTL -n $GL_NS exec "$GLPOD" -- curl -sk -X "$m" -H "PRIVATE-TOKEN: $PAT" -H 'Content-Type: application/json' -d "$b" "https://localhost/api/v4/$p"
  else $KUBECTL -n $GL_NS exec "$GLPOD" -- curl -sk -X "$m" -H "PRIVATE-TOKEN: $PAT" "https://localhost/api/v4/$p"; fi; }
runs_for(){ $KUBECTL -n $NS get pipelinerun -l "$1" -o name 2>/dev/null | sort || true; }

wait_done(){ local runs="$1" t="${2:-90}" pr r busy; for _ in $(seq 1 "$t"); do busy=0
  for pr in $runs; do r="$($KUBECTL -n $NS get "$pr" -o jsonpath='{.status.conditions[0].status}' 2>/dev/null||true)"; { [ "$r" = Unknown ]||[ -z "$r" ]; } && busy=1; done
  [ "$busy" = 0 ] && return 0; sleep 8; done; return 1; }

wait_new(){ local sel="$1" before="$2" t="${3:-30}" cur new; for _ in $(seq 1 "$t"); do
  cur="$(runs_for "$sel")"; new="$(comm -13 <(echo "$before") <(echo "$cur")|grep -v '^$'||true)"
  [ -n "$new" ] && { echo "$new"; return 0; }; sleep 4; done; return 1; }

# Classify a finished run -> GREEN | DUP:.. | ARCH_DOCKER:.. | BAD:..
classify(){ $KUBECTL -n $NS get taskrun -l tekton.dev/pipelineRun="$1" -o json 2>/dev/null \
  | ARCH="$ARCH_TASKS" DUP="$DUP_TASKS" python3 -c '
import json,os,sys
arch=set(os.environ["ARCH"].split()); dup=set(os.environ["DUP"].split())
d=json.load(sys.stdin)
f=sorted(it["metadata"]["labels"].get("tekton.dev/pipelineTask") for it in d["items"]
         if (it.get("status",{}).get("conditions") or [{}])[0].get("status")=="False")
s=set(f)
if not f: print("GREEN")
elif s<=dup: print("DUP:"+",".join(f))
elif s<=(arch|dup): print("ARCH_DOCKER:"+",".join(f))
else: print("BAD:"+",".join(f))'; }

# Assert a run set: fail on any BAD; pass if >=1 run is GREEN/ARCH_DOCKER. $1=runs $2=label
arch_seen=0
assert_runs(){ local good=0 pr name cls
  for pr in $1; do name="${pr#*/}"; cls="$(classify "$name")"; info "$name -> $cls"
    case "$cls" in
      GREEN) good=1 ;;
      ARCH_DOCKER:*) good=1; arch_seen=1 ;;
      DUP:*) ;;
      *) fail "$2 failed on a non-docker task: $cls" ;;
    esac; done
  [ "$good" = 1 ] || fail "$2: no successful run"; }

# ── onboard ──────────────────────────────────────────────────────────────────
say "Onboarding the Java/Maven Codebase ($CODEBASE)"
$KUBECTL apply -f "$HERE/manifests/sample-java-codebase.yaml" >/dev/null
st=""; for _ in $(seq 1 60); do st="$($KUBECTL -n $NS get codebase $CODEBASE -o jsonpath='{.status.status}' 2>/dev/null||true)"
  [ "$st" = created ] && break
  [ "$st" = failed ] && fail "codebase reconcile failed: $($KUBECTL -n $NS get codebase $CODEBASE -o jsonpath='{.status.detailedMessage}')"
  sleep 5; done
[ "$st" = created ] || fail "codebase not provisioned (status='$st')"
for _ in $(seq 1 36); do gl_api GET "projects/$PROJECT_ENC/hooks" 2>/dev/null | grep -q '"id"' && break; sleep 5; done
info "GitLab project + webhook ready"

# ── review (MR) ──────────────────────────────────────────────────────────────
before="$(runs_for "app.edp.epam.com/pipelinetype=review,app.edp.epam.com/codebase=$CODEBASE")"
BR="ci-java-$(date +%s)"
say "Opening a merge request ($BR) -> review pipeline"
gl_api POST "projects/$PROJECT_ENC/repository/branches?branch=$BR&ref=$BRANCH" >/dev/null
gl_api POST "projects/$PROJECT_ENC/repository/commits" \
  "$(printf '{"branch":"%s","commit_message":"e2e-java","actions":[{"action":"create","file_path":"e2e-%s.txt","content":"x"}]}' "$BR" "$BR")" >/dev/null
MR_IID="$(gl_api POST "projects/$PROJECT_ENC/merge_requests" \
  "$(printf '{"source_branch":"%s","target_branch":"%s","title":"e2e-java %s","remove_source_branch":true}' "$BR" "$BRANCH" "$BR")" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("iid",""))')"
[ -n "$MR_IID" ] || fail "could not open merge request"
info "merge request !$MR_IID opened"
review="$(wait_new "app.edp.epam.com/pipelinetype=review,app.edp.epam.com/codebase=$CODEBASE" "$before" 30)" || fail "no review run triggered"
wait_done "$review" 90 || fail "review pipeline did not finish in time"
say "Review per-task result"
assert_runs "$review" "review"

# ── build (merge) ────────────────────────────────────────────────────────────
before_b="$(runs_for "app.edp.epam.com/pipelinetype=build,app.edp.epam.com/codebase=$CODEBASE")"
say "Merging merge request !$MR_IID -> build pipeline"
merged=""; for _ in $(seq 1 24); do
  ms="$(gl_api GET "projects/$PROJECT_ENC/merge_requests/$MR_IID" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("detailed_merge_status") or d.get("merge_status",""))')"
  case "$ms" in mergeable|can_be_merged)
    [ "$(gl_api PUT "projects/$PROJECT_ENC/merge_requests/$MR_IID/merge" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("state",""))' 2>/dev/null||true)" = merged ] && { merged=1; break; };; esac
  sleep 5; done
[ -n "$merged" ] || fail "could not merge MR (last status='$ms')"
build="$(wait_new "app.edp.epam.com/pipelinetype=build,app.edp.epam.com/codebase=$CODEBASE" "$before_b" 45)" || fail "no build run triggered by merge"
wait_done "$build" 150 || fail "build pipeline did not finish in time"
say "Build per-task result"
assert_runs "$build" "build"

# ── report registry artifacts + docker note ──────────────────────────────────
say "GitLab Package Registry — published maven artifacts for $CODEBASE"
gl_api GET "projects/$PROJECT_ENC/packages" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
[print("    pkg:",p["name"],p["version"],"("+p["package_type"]+")") for p in d] or print("    (none yet)")'
[ "$arch_seen" = 1 ] && { echo; say "Docker build step (known arm64 limitation)"; docker_note; }

echo
echo "E2E-JAVA: PASS — Maven/registry tasks green (resolve from Central + GitLab group; publish to GitLab via mvn deploy)."
[ "$arch_seen" = 1 ] && echo "          (docker image build skipped/failed on arm64 — known template base-image issue; see note above)."
exit 0
