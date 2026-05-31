#!/usr/bin/env bash
# End-to-end validation of the GitLab -> KubeRocketCI webhook -> Tekton flow.
#
# Fully automated (no manual/UI steps): provisions the sample Codebase, opens a
# GitLab merge request via the API, waits for the triggered review PipelineRun,
# and asserts it is GREEN EXCEPT the `sonar` task (which needs a SonarQube
# instance that this testbed intentionally does not deploy).
#
# Exit 0 = PASS (review pipeline green except sonar), non-zero = FAIL.
#
# Note on duplicates: GitLab delivers the merge_request webhook twice (open, then
# an update as it recomputes merge status); both match the chart's gitlab-review
# trigger, so two runs appear. They post the same commit-status context, so the
# second gets HTTP 400 at report-pipeline-start-to-gitlab and fails fast. That is
# the expected "duplicate" run; the other is the real "green except sonar" run.
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
GL_NS="gitlab"
PROJECT_ENC="krci%2Ftest-go-app"
KUBECTL="kubectl --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
say() { echo "==> $*"; }
fail() { echo "E2E RESULT: FAIL — $*"; exit 1; }

say "Applying the sample Codebase (test-go-app)"
$KUBECTL apply -f "$HERE/manifests/sample-codebase.yaml" >/dev/null

say "Waiting for the Codebase to be provisioned in GitLab (project + template push)"
st=""
for _ in $(seq 1 72); do
  st="$($KUBECTL -n "$NS" get codebase test-go-app -o jsonpath='{.status.status}' 2>/dev/null || true)"
  [ "$st" = "created" ] && break
  [ "$st" = "failed" ] && fail "codebase test-go-app reconcile failed: $($KUBECTL -n "$NS" get codebase test-go-app -o jsonpath='{.status.detailedMessage}')"
  sleep 5
done
[ "$st" = "created" ] || fail "codebase test-go-app not provisioned (status='$st')"

PAT="$($KUBECTL -n "$NS" get secret ci-gitlab -o jsonpath='{.data.token}' | base64 -d)"
GLPOD="$($KUBECTL -n "$GL_NS" get pod -l app=gitlab -o jsonpath='{.items[0].metadata.name}')"

say "Waiting for the codebase-operator to create the project webhook"
for _ in $(seq 1 36); do
  if $KUBECTL -n "$GL_NS" exec "$GLPOD" -- bash -c "curl -sk -H 'PRIVATE-TOKEN: $PAT' https://localhost/api/v4/projects/$PROJECT_ENC/hooks" 2>/dev/null | grep -q '"id"'; then
    break
  fi
  sleep 5
done

# Snapshot existing review runs so we can pick out the ones THIS MR triggers.
before="$($KUBECTL -n "$NS" get pipelinerun -o name 2>/dev/null | grep 'review-test-go-app' | sort || true)"

BR="ci-e2e-$(date +%s)"
say "Opening a merge request (branch $BR) to trigger the review pipeline"
$KUBECTL -n "$GL_NS" exec "$GLPOD" -- bash -c "
set -e
curl -sk -o /dev/null -X POST -H 'PRIVATE-TOKEN: $PAT' 'https://localhost/api/v4/projects/$PROJECT_ENC/repository/branches?branch=$BR&ref=main'
curl -sk -o /dev/null -X POST -H 'PRIVATE-TOKEN: $PAT' -H 'Content-Type: application/json' -d '{\"branch\":\"$BR\",\"commit_message\":\"e2e\",\"actions\":[{\"action\":\"create\",\"file_path\":\"e2e-$BR.txt\",\"content\":\"e2e\"}]}' 'https://localhost/api/v4/projects/$PROJECT_ENC/repository/commits'
curl -sk -o /dev/null -X POST -H 'PRIVATE-TOKEN: $PAT' -H 'Content-Type: application/json' -d '{\"source_branch\":\"$BR\",\"target_branch\":\"main\",\"title\":\"e2e $BR\"}' 'https://localhost/api/v4/projects/$PROJECT_ENC/merge_requests'
" >/dev/null

say "Waiting for the webhook to create the review PipelineRun(s)"
new=""
for _ in $(seq 1 30); do
  cur="$($KUBECTL -n "$NS" get pipelinerun -o name 2>/dev/null | grep 'review-test-go-app' | sort || true)"
  new="$(comm -13 <(echo "$before") <(echo "$cur") | grep -v '^$' || true)"
  [ -n "$new" ] && break
  sleep 4
done
[ -n "$new" ] || fail "no review PipelineRun was triggered (webhook did not reach the EventListener)"
echo "    triggered: $(echo "$new" | tr '\n' ' ')"

say "Waiting for the run(s) to finish"
for _ in $(seq 1 90); do
  busy=0
  for pr in $new; do
    r="$($KUBECTL -n "$NS" get "$pr" -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)"
    [ "$r" = "Unknown" ] || [ -z "$r" ] && busy=1
  done
  [ "$busy" = "0" ] && break
  sleep 8
done

# Classify each run: GREEN_EXCEPT_SONAR | DUP_REPORT_FAIL | BAD:<failed tasks>
say "Evaluating per-task results"
verdict_seen=""
green_found=0
for pr in $new; do
  name="${pr#*/}"
  cls="$($KUBECTL -n "$NS" get taskrun -l tekton.dev/pipelineRun="$name" -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
res={}
for it in d['items']:
    t=it['metadata']['labels'].get('tekton.dev/pipelineTask','?')
    conds=it.get('status',{}).get('conditions') or [{}]
    res[t]=conds[0].get('status')
failed=sorted(t for t,s in res.items() if s=='False')
report_ok = res.get('report-pipeline-start-to-gitlab')=='True'
if failed==['sonar'] and report_ok:
    print('GREEN_EXCEPT_SONAR')
elif failed and all(f in ('report-pipeline-start-to-gitlab','gitlab-set-failure-status') for f in failed):
    print('DUP_REPORT_FAIL')
else:
    print('BAD:'+(','.join(failed) or 'none'))
")"
  echo "    $name -> $cls"
  verdict_seen="$verdict_seen $cls"
  [ "$cls" = "GREEN_EXCEPT_SONAR" ] && green_found=1
done

for v in $verdict_seen; do
  case "$v" in
    GREEN_EXCEPT_SONAR|DUP_REPORT_FAIL) ;;
    *) fail "a run failed on an unexpected task ($v) — pipeline is not green-except-sonar" ;;
  esac
done
[ "$green_found" = "1" ] || fail "no run reached the expected 'green except sonar' state"

echo "E2E RESULT: PASS — review pipeline is green except the sonar task (SonarQube not deployed; next phase)."
