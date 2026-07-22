#!/usr/bin/env bash
# Full end-to-end validation of the GitLab -> KubeRocketCI -> Tekton -> Argo CD flow.
#
# Fully automated (no manual/UI steps). Phases:
#   1. provision the sample Codebase (test-go-app) in GitLab,
#   2. create the "demo" CDPipeline + "dev" Stage (triggerType: Auto) up front, so
#      it is in place when the build later updates the CodebaseImageStream,
#   3. open a merge request   -> review PipelineRun -> assert fully green,
#   4. merge the merge request -> build PipelineRun -> assert fully green; kaniko
#      pushes the image and updates CodebaseImageStream test-go-app-main,
#   5. the CBIS update auto-fires the deploy (Auto trigger -> cd-pipeline-operator
#      creates a CDStageDeploy) -> deploy PipelineRun -> assert green AND the
#      workload is Available in ns krci-demo-dev on the freshly built tag.
#
# Exit 0 = PASS (review + build + deploy all green, app deployed), non-zero = FAIL.
#
# Note on duplicates: GitLab can deliver the merge_request webhook twice (open, then
# an update as it recomputes merge status); both match the gitlab-review trigger, so
# two review runs can appear. They post the same commit-status context, so the second
# fails fast at report-pipeline-start-to-gitlab (HTTP 400). That is the expected
# "duplicate" run; the other is the real "fully green" run. The merge action fires the
# build trigger once.
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
GL_NS="gitlab"
PROJECT_ENC="krci%2Ftest-go-app"
CODEBASE="test-go-app"
BRANCH="main"
CB_BRANCH="${CODEBASE}-${BRANCH}"        # CodebaseBranch / CodebaseImageStream name
CDPIPELINE="demo"
STAGE="dev"
DEPLOY_NS="krci-${CDPIPELINE}-${STAGE}"  # krci-demo-dev
KUBECTL="kubectl --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

say()  { echo "==> $*"; }
info() { echo "    $*"; }
fail() { echo "E2E RESULT: FAIL — $*"; exit 1; }

# Run a GitLab REST call from inside the gitlab pod (the only place the self-signed
# https://localhost API is reachable). Usage: gl_api METHOD PATH [JSON_BODY]
gl_api() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    $KUBECTL -n "$GL_NS" exec "$GLPOD" -- curl -sk -X "$method" \
      -H "PRIVATE-TOKEN: $PAT" -H "Content-Type: application/json" \
      -d "$body" "https://localhost/api/v4/$path"
  else
    $KUBECTL -n "$GL_NS" exec "$GLPOD" -- curl -sk -X "$method" \
      -H "PRIVATE-TOKEN: $PAT" "https://localhost/api/v4/$path"
  fi
}

# Snapshot PipelineRun names matching a label selector (sorted, one per line).
runs_for() { $KUBECTL -n "$NS" get pipelinerun -l "$1" -o name 2>/dev/null | sort || true; }

# Classify a finished PipelineRun's taskruns: ALL_GREEN | DUP_REPORT_FAIL | BAD:<tasks>.
classify_run() {
  $KUBECTL -n "$NS" get taskrun -l tekton.dev/pipelineRun="$1" -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
res={}
for it in d['items']:
    t=it['metadata']['labels'].get('tekton.dev/pipelineTask','?')
    conds=it.get('status',{}).get('conditions') or [{}]
    res[t]=conds[0].get('status')
failed=sorted(t for t,s in res.items() if s=='False')
if not failed:
    print('ALL_GREEN')
elif all(f in ('report-pipeline-start-to-gitlab','gitlab-report-pipeline-status','gitlab-set-failure-status') for f in failed):
    print('DUP_REPORT_FAIL')
else:
    print('BAD:'+','.join(failed))
"
}

# Wait for every run in $1 (newline-separated 'pipelinerun/<name>') to finish.
wait_runs_done() {
  local runs="$1" tries="${2:-90}" pr r busy
  for _ in $(seq 1 "$tries"); do
    busy=0
    for pr in $runs; do
      r="$($KUBECTL -n "$NS" get "$pr" -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)"
      { [ "$r" = "Unknown" ] || [ -z "$r" ]; } && busy=1
    done
    [ "$busy" = "0" ] && return 0
    sleep 8
  done
  return 1
}

# Find PipelineRuns matching selector $1 that are NOT in the newline list $2 (the
# pre-snapshot). Polls up to $3 iterations (4s each). Echoes the new run names.
wait_new_runs() {
  local selector="$1" before="$2" tries="${3:-30}" cur new
  for _ in $(seq 1 "$tries"); do
    cur="$(runs_for "$selector")"
    new="$(comm -13 <(echo "$before") <(echo "$cur") | grep -v '^$' || true)"
    [ -n "$new" ] && { echo "$new"; return 0; }
    sleep 4
  done
  return 1
}

# Assert at least one run in $1 is ALL_GREEN and none failed on an unexpected task.
assert_green() {
  local runs="$1" what="$2" pr name cls green=0 v seen=""
  say "Evaluating per-task results ($what)"
  for pr in $runs; do
    name="${pr#*/}"
    cls="$(classify_run "$name")"
    info "$name -> $cls"
    seen="$seen $cls"
    [ "$cls" = "ALL_GREEN" ] && green=1
  done
  for v in $seen; do
    case "$v" in
      ALL_GREEN|DUP_REPORT_FAIL) ;;
      *) fail "$what: a run failed on an unexpected task ($v) — pipeline is not fully green" ;;
    esac
  done
  [ "$green" = "1" ] || fail "$what: no run reached the expected fully-green state"
}

# ---------------------------------------------------------------------------
# Phase 1 — provision the sample Codebase in GitLab.
# ---------------------------------------------------------------------------
say "Applying the sample Codebase ($CODEBASE)"
$KUBECTL apply -f "$HERE/manifests/sample-codebase.yaml" >/dev/null

say "Waiting for the Codebase to be provisioned in GitLab (project + template push)"
st=""
for _ in $(seq 1 72); do
  st="$($KUBECTL -n "$NS" get codebase "$CODEBASE" -o jsonpath='{.status.status}' 2>/dev/null || true)"
  [ "$st" = "created" ] && break
  [ "$st" = "failed" ] && fail "codebase $CODEBASE reconcile failed: $($KUBECTL -n "$NS" get codebase "$CODEBASE" -o jsonpath='{.status.detailedMessage}')"
  sleep 5
done
[ "$st" = "created" ] || fail "codebase $CODEBASE not provisioned (status='$st')"

PAT="$($KUBECTL -n "$NS" get secret ci-gitlab -o jsonpath='{.data.token}' | base64 -d)"
GLPOD="$($KUBECTL -n "$GL_NS" get pod -l app=gitlab -o jsonpath='{.items[0].metadata.name}')"

say "Waiting for the codebase-operator to create the project webhook"
for _ in $(seq 1 36); do
  gl_api GET "projects/$PROJECT_ENC/hooks" 2>/dev/null | grep -q '"id"' && break
  sleep 5
done

# ---------------------------------------------------------------------------
# Phase 2 — create the demo CDPipeline + dev Stage (Auto) up front.
# The cdpipeline validating webhook requires inputDockerStreams to exist, so wait
# for the (initially empty) CodebaseImageStream the CodebaseBranch creates. The
# Stage must exist BEFORE the build: triggerType Auto deploys on the CBIS *update*,
# so the build updating the stream is what later fires the deploy.
# ---------------------------------------------------------------------------
say "Waiting for the CodebaseImageStream $CB_BRANCH to exist"
for _ in $(seq 1 36); do
  $KUBECTL -n "$NS" get codebaseimagestream "$CB_BRANCH" >/dev/null 2>&1 && break
  sleep 5
done
$KUBECTL -n "$NS" get codebaseimagestream "$CB_BRANCH" >/dev/null 2>&1 \
  || fail "CodebaseImageStream $CB_BRANCH was not created by the CodebaseBranch"

say "Creating the $CDPIPELINE CDPipeline + $STAGE Stage (triggerType: Auto)"
$KUBECTL apply -f "$HERE/manifests/cdpipeline-demo.yaml"

say "Waiting for the cd-pipeline-operator to reconcile the Stage (namespace $DEPLOY_NS)"
for _ in $(seq 1 36); do
  $KUBECTL get ns "$DEPLOY_NS" >/dev/null 2>&1 && break
  sleep 5
done
$KUBECTL get ns "$DEPLOY_NS" >/dev/null 2>&1 || fail "Stage did not create the deploy namespace $DEPLOY_NS"

# Snapshot deploy runs now: the build hasn't run yet, so any deploy run we see after
# the build is the one the Auto trigger created for the freshly built image.
before_deploy="$(runs_for "app.edp.epam.com/pipelinetype=deploy,app.edp.epam.com/cdpipeline=$CDPIPELINE")"

# ---------------------------------------------------------------------------
# Phase 3 — open a merge request -> review pipeline -> assert green.
# ---------------------------------------------------------------------------
before_review="$(runs_for "app.edp.epam.com/pipelinetype=review,app.edp.epam.com/codebase=$CODEBASE")"

BR="ci-e2e-$(date +%s)"
say "Opening a merge request (branch $BR) to trigger the review pipeline"
gl_api POST "projects/$PROJECT_ENC/repository/branches?branch=$BR&ref=$BRANCH" >/dev/null
gl_api POST "projects/$PROJECT_ENC/repository/commits" \
  "$(printf '{"branch":"%s","commit_message":"e2e","actions":[{"action":"create","file_path":"e2e-%s.txt","content":"e2e"}]}' "$BR" "$BR")" >/dev/null
MR_JSON="$(gl_api POST "projects/$PROJECT_ENC/merge_requests" \
  "$(printf '{"source_branch":"%s","target_branch":"%s","title":"e2e %s","remove_source_branch":true}' "$BR" "$BRANCH" "$BR")")"
MR_IID="$(echo "$MR_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('iid',''))")"
[ -n "$MR_IID" ] || fail "could not create/parse merge request (response: $MR_JSON)"
info "merge request !$MR_IID opened"

say "Waiting for the webhook to create the review PipelineRun(s)"
review="$(wait_new_runs "app.edp.epam.com/pipelinetype=review,app.edp.epam.com/codebase=$CODEBASE" "$before_review" 30)" \
  || fail "no review PipelineRun was triggered (webhook did not reach the EventListener)"
info "triggered: $(echo "$review" | tr '\n' ' ')"

say "Waiting for the review run(s) to finish"
wait_runs_done "$review" 90 || fail "review pipeline(s) did not finish in time"
assert_green "$review" "review"

# ---------------------------------------------------------------------------
# Phase 4 — merge the MR -> build pipeline -> assert green.
# ---------------------------------------------------------------------------
before_build="$(runs_for "app.edp.epam.com/pipelinetype=build,app.edp.epam.com/codebase=$CODEBASE")"

say "Merging merge request !$MR_IID (action=merge fires the build trigger)"
merged=""
for _ in $(seq 1 24); do
  ms="$(gl_api GET "projects/$PROJECT_ENC/merge_requests/$MR_IID" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('detailed_merge_status') or d.get('merge_status',''))")"
  case "$ms" in
    mergeable|can_be_merged)
      resp="$(gl_api PUT "projects/$PROJECT_ENC/merge_requests/$MR_IID/merge")"
      state="$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || true)"
      [ "$state" = "merged" ] && { merged=1; break; }
      ;;
  esac
  sleep 5
done
[ -n "$merged" ] || fail "merge request !$MR_IID could not be merged (last merge_status='$ms')"
info "merge request !$MR_IID merged"

say "Waiting for the merge webhook to create the build PipelineRun"
build="$(wait_new_runs "app.edp.epam.com/pipelinetype=build,app.edp.epam.com/codebase=$CODEBASE" "$before_build" 45)" \
  || fail "no build PipelineRun was triggered by the merge"
info "triggered: $(echo "$build" | tr '\n' ' ')"

say "Waiting for the build run(s) to finish (kaniko build+push can take several minutes)"
wait_runs_done "$build" 150 || fail "build pipeline(s) did not finish in time"
assert_green "$build" "build"

# ---------------------------------------------------------------------------
# Phase 5 — the build updated the CBIS; capture the tag for the final assertion.
# ---------------------------------------------------------------------------
say "Reading the built image tag from CodebaseImageStream $CB_BRANCH"
TAG=""
for _ in $(seq 1 24); do
  TAG="$($KUBECTL -n "$NS" get codebaseimagestream "$CB_BRANCH" -o json 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
tags=d.get('spec',{}).get('tags') or []
tags.sort(key=lambda t:t.get('created',''))
print(tags[-1]['name'] if tags else '')
")"
  [ -n "$TAG" ] && break
  sleep 5
done
[ -n "$TAG" ] || fail "no tag found in CodebaseImageStream $CB_BRANCH after the build"
info "built tag: $TAG"

# ---------------------------------------------------------------------------
# Phase 6 — Auto trigger: the CBIS update auto-deploys the new image. Wait for the
# deploy run the operator created, assert it is green, and confirm the workload.
# ---------------------------------------------------------------------------
say "Waiting for the Auto trigger to deploy tag $TAG (cd-pipeline-operator -> CDStageDeploy -> deploy run)"
deploy="$(wait_new_runs "app.edp.epam.com/pipelinetype=deploy,app.edp.epam.com/cdpipeline=$CDPIPELINE" "$before_deploy" 60)" \
  || fail "Auto trigger did not create a deploy PipelineRun for $CDPIPELINE/$STAGE after the build"
info "triggered: $(echo "$deploy" | tr '\n' ' ')"

say "Waiting for the deploy run(s) to finish"
wait_runs_done "$deploy" 90 || fail "deploy pipeline(s) did not finish in time"
assert_green "$deploy" "deploy"

say "Verifying the application is deployed in $DEPLOY_NS on tag $TAG"
ok=""
for _ in $(seq 1 60); do
  ok="$($KUBECTL -n "$DEPLOY_NS" get deploy -o json 2>/dev/null | python3 -c "
import json,sys
tag='$TAG'
d=json.load(sys.stdin)
for dep in d.get('items',[]):
    st=dep.get('status',{})
    avail=st.get('availableReplicas',0)
    imgs=[c['image'] for c in dep['spec']['template']['spec']['containers']]
    if avail and any(tag in i for i in imgs):
        print('OK',dep['metadata']['name'],imgs[0]); break
")"
  [ -n "$ok" ] && break
  sleep 5
done
[ -n "$ok" ] || fail "no Available Deployment running tag $TAG found in $DEPLOY_NS"
info "$ok"

echo "E2E RESULT: PASS — review + build + deploy all green; $CODEBASE:$TAG auto-deployed to $DEPLOY_NS."
