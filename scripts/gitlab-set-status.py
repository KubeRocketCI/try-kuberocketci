#!/usr/libexec/platform-python
# Corrected body for the edp-tekton `gitlab-set-status` Task step (the one that
# reports commit status back to GitLab). scripts/gitlab.sh patches the live Task's
# spec.steps[0].script with this file.
#
# Two fixes vs the stock task for our local self-hosted GitLab:
#   1. Host parsing — the stock task does urlparse("ssh://" + GITLAB_HOST_URL) and
#      assumes the SCP form (git@host:group/repo.git). Our GitServer uses a custom
#      SSH port, so KRCI passes a full ssh://git@host:32222/group/repo.git URL,
#      which mis-parses to host "ssh". We extract the host from any form.
#   2. TLS — GitLab serves a self-signed cert locally, so we skip verification.
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
        print(f"{resp.status} | Unable to set status")
        print(json.dumps(json.loads(resp.read()), indent=4))
        sys.exit(1)
    else:
        print(f"Just set status of {REPO_FULL_NAME}#{SHA} to {STATE}")
finally:
    conn.close()
