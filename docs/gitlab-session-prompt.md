# System prompt — fresh session: GitLab + edp-tekton webhook integration

Copy everything in the fenced block below as the opening message of a new session.

```
You are continuing work on a local KubeRocketCI test bed. Repo:
/Users/sergk/my_projects/krci-k8s (kind cluster, context kind-krci, ns krci).
Read docs/gitlab-plan.md FIRST — it is the authoritative plan; follow it and tick
off its "Open items to verify" rather than assuming.

## Current state (already done, verified green)
- `make testbed` brings up: kind v1.35.0, ingress-nginx, cert-manager v1.16.2,
  Tekton Pipelines v1.6.0 / Triggers v0.34.0, KubeRocketCI edp-install 3.13.5,
  kube-prometheus-stack 84.5.0, Tekton Results v0.17.2 (+ minimal Postgres).
  All commands are in the Makefile (`make help`). Versions are pinned there.
- KubeRocketCI core runs in ns `krci`: cd-pipeline-operator, codebase-operator,
  gitfusion, tekton-cache, tekton-interceptor.
- `values/edp-install.yaml` currently has `global.gitProviders: [github]` and the
  in-cluster portal disabled (it's run from source at ../portal/krci-portal).
- The `gitlab` ClusterInterceptor already exists; there is NO EventListener yet
  (because gitlab isn't in gitProviders).
- Phase-2 assets already drafted but NOT yet validated:
  manifests/gitlab.yaml (gitlab-ce omnibus pod) and scripts/gitlab.sh
  (deploy + CoreDNS rewrite + root PAT + SSH key + ci-gitlab secret + GitServer CR).
  `make gitlab` runs the script.

## Your task
Deploy minimal self-hosted GitLab in the cluster and integrate it so a GitLab
push/MR triggers a KubeRocketCI Tekton pipeline via the edp-tekton GitLab
EventListener + gitlab ClusterInterceptor. Keep config minimal (HTTP only, no TLS,
single omnibus pod, registry/KAS/prometheus off). End state: creating a Codebase
against the gitlab GitServer auto-creates a working project webhook, and a push
starts a PipelineRun that appears in Tekton Results.

## Critical specifics (verified this session)
- Enabling GitLab = add `gitlab` to `global.gitProviders` in values/edp-install.yaml
  then `make krci`; that renders EventListener `el-edp-gitlab` (+ Service
  `el-edp-gitlab`) and GitLab TriggerBindings/Templates in ns krci. Verify the EL
  pod is Running before wiring webhooks.
- Webhook flow: GitServer CR + token secret → codebase-operator creates the GitLab
  project webhook → GitLab POSTs to el-edp-gitlab → gitlab ClusterInterceptor
  validates X-Gitlab-Token → TriggerTemplate creates the PipelineRun.
- Split-horizon DNS: gitlab.127.0.0.1.nip.io must resolve to localhost for the
  browser AND to the in-cluster service for pods (scripts/gitlab.sh handles this
  via a CoreDNS rewrite). For the webhook target, PREFER pointing it at the
  in-cluster EventListener svc (http://el-edp-gitlab.krci.svc.cluster.local:8080)
  so it never needs ingress/DNS; fall back to an ingress host + CoreDNS rewrite if
  codebase-operator requires an external URL.
- GitLab blocks webhooks to local/internal IPs by default — enable Admin →
  Settings → Network → Outbound requests → "Allow requests to the local network
  from webhooks/system hooks".
- Confirm Docker has RAM headroom; GitLab adds ~3–4GB on top of the running
  testbed. If tight, consider tearing down Prometheus/Results during GitLab
  bring-up, or bump Docker Desktop memory.

## Verify against the LIVE cluster, do not assume
- Exact GitServer CRD schema (apiVersion v2.edp.epam.com/v1): the field for the
  webhook URL, gitHost/gitUser/sshPort/httpsPort, nameSshKeySecret. Run
  `kubectl explain gitserver.spec` and check the codebase-operator CRD.
- Where edp-tekton 0.24.x reads the webhook secret token (GitServer secret vs a
  per-EventListener secret) — inspect `el-edp-gitlab` and its TriggerBindings.
- Whether scripts/gitlab.sh's GitServer block matches the actual CRD (it predates
  this verification — fix it as needed).

## Working style for this repo (important)
- This shell's stdout buffer stalls; it flushes when a background task completes.
  Run shell snippets that write to a file and Read the file, or use run_in_background
  for long ops + a Monitor for completion. Long installs: background + monitor.
- Each Makefile capability target is independent/idempotent — rebuild one component
  without touching the rest. Use `make status` to see everything.
- Keep changes minimal and the README/Makefile in sync. The README's "phase 2"
  GitLab note should be promoted to documented once the flow is green.
- There is project memory under
  /Users/sergk/.claude/projects/-Users-sergk-my-projects-krci-k8s/memory/
  (MEMORY.md index + krci-local-install-facts, krci-portal-local-dev,
  krci-testbed-capabilities). Read it for context; add a krci-gitlab note when done.

Start by reading docs/gitlab-plan.md and confirming the current cluster state
(make status; kubectl -n krci get eventlistener,gitservers), then proceed.
```
