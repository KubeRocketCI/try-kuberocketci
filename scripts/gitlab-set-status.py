#!/usr/libexec/platform-python
# Body for the edp-tekton `gitlab-set-status` Task step (the one that reports commit
# status back to GitLab). scripts/gitlab-integrate.sh patches the live Task's
# spec.steps[0].script with this file — it mirrors the upstream script with two
# deviations for our self-hosted GitLab (kept minimal):
#   1. Host parsing — the stock task does urlparse("ssh://" + GITLAB_HOST_URL) and
#      assumes the SCP form (git@host:group/repo.git). Our GitServer uses a custom
#      SSH port, so KRCI passes a full ssh://git@host:32222/group/repo.git URL,
#      which mis-parses to host "ssh". We extract the host from any form.
#   2. TLS — GitLab serves a self-signed cert locally, so we skip verification.
#
# The review pipeline's finally reporter is a single unguarded task that passes
# PIPELINE_STATUS=$(tasks.status); when set, the script derives STATE/DESCRIPTION
# from that aggregate. Build and review pipelines both pass PIPELINE_STATUS; build
# reporters vote on the clone result.
#
# Tekton substitutes the params placeholders below at TaskRun time. (Do not write
# a params reference inside a comment — Tekton validates those against real params.)
import os
import sys
import json
import ssl
import http.client
import urllib.parse

GITLAB_TOKEN = os.getenv("GITLAB_TOKEN")
RAW_HOST = "$(params.GITLAB_HOST_URL)"
API_PATH_PREFIX = "$(params.API_PATH_PREFIX)"
REPO_FULL_NAME = "$(params.REPO_FULL_NAME)"
SHA = "$(params.SHA)"
STATE = "$(params.STATE)"
CONTEXT = "$(params.CONTEXT)"
TARGET_URL = "$(params.TARGET_URL)"
DESCRIPTION = "$(params.DESCRIPTION)"

PIPELINE_STATUS = "$(params.PIPELINE_STATUS)"
# The cancel-reason annotation the pipeline queue (or the interceptor) stamps in
# the same patch that cancels the run propagates to this pod. Its absence on a
# cancelled run means the cancellation came from elsewhere (kubectl, portal).
CANCEL_REASON = os.getenv("QUEUE_CANCEL_REASON", "")

if PIPELINE_STATUS:
    # Single-reporter mode: derive the state from the aggregate, so every terminal
    # shape is covered.
    if PIPELINE_STATUS == "Succeeded":
        STATE, DESCRIPTION = "success", "PASSED"
    elif CANCEL_REASON:
        # The queue stamped a cancel reason: Failed means the cancellation
        # caught a task mid-flight, Completed means it landed between tasks.
        STATE = "canceled"
        DESCRIPTION = "SUPERSEDED BY NEWER COMMIT" if CANCEL_REASON == "superseded" else "CANCELED"
    elif PIPELINE_STATUS == "Failed":
        STATE, DESCRIPTION = "failed", "FAILED"
    elif PIPELINE_STATUS == "Completed":
        # Tasks were skipped by when-guards but none failed - a legitimate
        # success shape for build pipelines. Manual cancels that land between
        # tasks carry no annotation and are reported as success; accepted
        # trade-off, see the clone-result-voting design doc.
        STATE, DESCRIPTION = "success", "PASSED"
    else:
        # None: no aggregate available; not expected in a finally task.
        STATE, DESCRIPTION = "failed", "UNKNOWN"
    print(f"Derived state '{STATE}' ({DESCRIPTION}) from aggregate '{PIPELINE_STATUS}'")
elif STATE == "failed" and CANCEL_REASON:
    # Explicit-STATE callers (e.g. build pipelines' failure vote): a gracefully
    # cancelled run reaches the failure task looking like a genuine failure.
    STATE = "canceled"
    DESCRIPTION = "SUPERSEDED BY NEWER COMMIT" if CANCEL_REASON == "superseded" else "CANCELED"
    print(f"PipelineRun was gracefully cancelled ({CANCEL_REASON}), reporting '{STATE}'")

# KRCI passes the git source URL here in any of these forms:
#   ssh://git@host:port/group/repo.git | git@host:group/repo.git |
#   https://host/group/repo.git | bare host. Extract the API host robustly.
raw = RAW_HOST.strip()
if "://" in raw:
    host = urllib.parse.urlparse(raw).hostname
else:
    host = raw.split("@")[-1].split("/")[0].split(":")[0]

headers = {
    "User-Agent": "TektonCD, the peaceful cat",
    "Authorization": f"Bearer {GITLAB_TOKEN}",
}
URLENCODED_REPO_NAME = urllib.parse.quote(REPO_FULL_NAME, safe="")
params = {
    "state": STATE,
    "context": CONTEXT,
    "target_url": TARGET_URL,
    "description": DESCRIPTION,
}
api_url = f"{API_PATH_PREFIX}/projects/{URLENCODED_REPO_NAME}/statuses/{SHA}?{urllib.parse.urlencode(params)}"
print(f"POST https://{host}{api_url}")
# GitLab serves a self-signed cert locally; skip verification.
ctx = ssl._create_unverified_context()
conn = http.client.HTTPSConnection(host, context=ctx)
try:
    conn.request("POST", api_url, headers=headers)
    resp = conn.getresponse()
    if not str(resp.status).startswith("2"):
        body = resp.read().decode()
        # GitLab enforces a state machine on commit statuses: posting a state that is
        # not a valid transition from an unfinished status in the same context (e.g.
        # `running` while a stuck previous run left the check running) fails with 400
        # "Cannot transition status". The check already shows a live state for this
        # SHA and the next terminal post resets it, so treat the conflict as already
        # reported instead of failing the run.
        if resp.status == 400 and "Cannot transition status" in body:
            print(f"Status of {REPO_FULL_NAME}#{SHA} already reports an active state, skipping '{STATE}'")
            print(body)
        else:
            print(f"{resp.status} | Unable to set status")
            try:
                print(json.dumps(json.loads(body), indent=4))
            except ValueError:
                print(body)
            sys.exit(1)
    else:
        print(f"Just set status of {REPO_FULL_NAME}#{SHA} to {STATE}")
finally:
    conn.close()
