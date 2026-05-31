# Phase 2 — Self-hosted GitLab + edp-tekton webhook integration

Goal: deploy a minimal self-hosted GitLab inside the kind testbed and wire it so a
push/MR in GitLab triggers a KubeRocketCI Tekton pipeline through the **edp-tekton
GitLab EventListener + gitlab ClusterInterceptor**.

## How the webhook path actually works (verified against this cluster)

- edp-tekton renders Git-provider resources **only for providers listed in
  `global.gitProviders`**. The cluster today has `[github]`, so it has
  `github-binding-*` TriggerBindings and **no EventListener at all**
  (`kubectl get eventlistener -A` → none).
- The `gitlab` **ClusterInterceptor already exists** (installed with Tekton
  Triggers — `kubectl get clusterinterceptor` shows bitbucket/cel/github/gitlab/slack).
- Adding `gitlab` to `gitProviders` makes edp-tekton create:
  - EventListener `el-edp-gitlab` (+ Service `el-edp-gitlab`) in ns `krci`,
  - GitLab TriggerBindings/TriggerTemplates,
  - the EventListener uses the `gitlab` ClusterInterceptor to validate the
    `X-Gitlab-Token` secret + filter event types.
- The **codebase-operator** auto-creates the webhook in GitLab (per-repo) using the
  GitServer + token, pointing it at the EventListener's external URL
  (`webhook.url` / the eventListener ingress host).

So the integration is: **GitServer CR + token secret → codebase-operator creates a
GitLab project webhook → GitLab POSTs to the `el-edp-gitlab` ingress → gitlab
ClusterInterceptor validates → TriggerTemplate spawns the PipelineRun.**

## The split-horizon DNS problem (the crux)

One hostname must resolve two ways:
- **Browser → GitLab UI**: `gitlab.127.0.0.1.nip.io` → 127.0.0.1 → kind ingress.
- **GitLab pod → EventListener webhook**: GitLab (in-cluster) cannot reach
  127.0.0.1. The webhook host (e.g. `el-gitlab.127.0.0.1.nip.io`) must resolve,
  from inside the cluster, to the ingress-nginx ClusterIP (or directly to the
  `el-edp-gitlab` service).

`scripts/gitlab.sh` already adds a CoreDNS `rewrite name` for the GitLab host →
in-cluster service. The same trick (or pointing the webhook URL straight at
`http://el-edp-gitlab.krci.svc.cluster.local:8080`) solves the EventListener side.
Simplest robust option for local: set the GitServer/webhook `url` to the in-cluster
EventListener service DNS, so GitLab→webhook never leaves the cluster network and
no ingress/DNS rewrite is needed for the webhook at all.

## Minimal-config decisions

- **GitLab**: single `gitlab/gitlab-ce` omnibus pod (already in
  `manifests/gitlab.yaml`), HTTP only, registry/KAS/prometheus disabled, SSH on
  nodePort 32222. Trim to ~3Gi req / 5Gi limit. Needs Docker ≥ ~10–12GB.
- **No TLS** anywhere (local only); webhook secret token is a plain shared secret.
- **Reuse** the existing `gitlab.sh` flow (deploy → CoreDNS rewrite → root PAT →
  SSH key → `ci-gitlab` secret → GitServer CR), but UPDATE it for the verified
  webhook path below.

## Step-by-step plan

1. **Enable the GitLab provider in edp-tekton.** In `values/edp-install.yaml`, add
   `gitlab` to `global.gitProviders` (keep or drop github). Re-run `make krci`.
   Verify `el-edp-gitlab` EventListener + Service appear in ns `krci` and the
   EventListener pod is Running.

2. **Deploy GitLab** (`manifests/gitlab.yaml`, via `make gitlab` / `gitlab.sh`).
   Wait for `/-/health`. Confirm UI at `http://gitlab.127.0.0.1.nip.io`.

3. **Bootstrap GitLab creds** (in `gitlab.sh`, already drafted): root PAT
   (api+repo scopes), SSH key, store in `krci` ns secret `ci-gitlab`.

4. **Register the GitServer** (CR `v2.edp.epam.com/v1`, `gitProvider: gitlab`,
   `gitHost: gitlab.127.0.0.1.nip.io`, `sshPort: 32222`, `nameSshKeySecret:
   ci-gitlab`, plus `webhookUrl` pointing at the EventListener — verify exact
   field name against the codebase-operator CRD in THIS cluster).

5. **Webhook reachability.** Decide one:
   - (a) in-cluster URL: webhook → `http://el-edp-gitlab.krci.svc.cluster.local:8080`
     (no ingress/DNS needed for the webhook), or
   - (b) ingress host `el-gitlab.127.0.0.1.nip.io` + CoreDNS rewrite → ingress-nginx.
   Prefer (a) for minimalism; fall back to (b) if codebase-operator insists on an
   external URL.

6. **End-to-end test.** Create a Codebase in the Portal (or a Codebase CR) using
   the gitlab GitServer; codebase-operator clones the template into GitLab and
   creates the project webhook. Push/MR → confirm a PipelineRun starts
   (`kubectl -n krci get pipelinerun -w`) and lands in Tekton Results.

## Open items to verify in-session (don't assume)

- Exact GitServer CRD schema in the running codebase-operator (field for webhook
  URL; `gitWebUrl` vs `webhookUrl`; whether `skipWebhookSSLVerification` exists).
- Whether the EventListener needs an ingress at all, or the in-cluster svc URL is
  accepted by codebase-operator as the webhook target.
- The `X-Gitlab-Token` secret wiring: where edp-tekton reads the webhook secret
  (the GitServer secret vs a per-EventListener secret) in chart 0.24.x.
- GitLab webhook "local network" restriction: GitLab blocks webhooks to local/
  internal addresses by default — must enable
  *Admin → Settings → Network → Outbound requests → Allow requests to the local
  network from webhooks*.
- Docker RAM headroom on top of the running testbed (KRCI + Prometheus + Results
  already use a chunk; GitLab adds ~3–4GB).

## Resolution — verified against the live cluster (2026-05-31)

All of the above is implemented and the trigger path is green. Findings that
differed from the original assumptions:

- **EventListener is NOT created by `gitProviders`.** Adding `gitlab` to
  `global.gitProviders` only renders the gitlab TriggerBindings/TriggerTemplates.
  The EventListener (`edp-gitlab`) + its Ingress (`event-listener-gitlab`, host
  `el-gitlab-krci.<wildcard>`) + Service (`el-edp-gitlab:8080`) are created
  **per-GitServer by the codebase-operator** when `spec.webhookUrl` is empty.
- **GitServer secret keys:** the `nameSshKeySecret` secret carries `token`,
  `username`, `id_rsa`, and **`secretString`** (the webhook X-Gitlab-Token the
  gitlab ClusterInterceptor validates). The operator sets the same value as the
  webhook token in GitLab. No per-EventListener secret.
- **Webhook URL:** leaving `webhookUrl` empty is the simplest path — the operator
  creates the EL+ingress and points the webhook at the ingress host. The in-cluster
  EL svc URL would require hand-building the EL, so we use the ingress + a CoreDNS
  rewrite (`el-gitlab-krci.<wildcard>` → ingress-nginx) instead.
- **HTTPS is mandatory.** The operator's GitLab REST client always uses `https://`
  (the GitServer CRD exposes only `httpsPort`). HTTP-only GitLab fails with
  "server gave HTTP response to HTTPS client". GitLab now serves TLS with a
  self-signed cert (secret `gitlab-tls`), and the operator is **patched to trust
  that CA** (mounted into `/etc/ssl/certs`; `skipWebhookSSLVerification` covers
  only webhooks, not the API client). The additive volume/mount survives
  `make krci` — Helm's 3-way merge preserves fields it doesn't own.
- **SSH port:** the gitlab Service must expose `32222 → 22` (the operator's SSH
  connection check + clone dial `gitHost:32222`).
- **GitLab local-network webhooks:** enabled programmatically via
  `ApplicationSetting … allow_local_requests_from_web_hooks_and_services = true`.
- **GitLab gotchas hit & fixed:** `grafana['enable']` is removed in omnibus 16.0+
  (breaks reconfigure); `/etc/gitlab` must be on a PVC or restarts rotate the
  secrets and the DB throws `OpenSSL::CipherError`; `progressDeadlineSeconds` must
  be raised so first boot doesn't trip `rollout status`; `/-/health` is blocked for
  the kubelet probe source unless the pod CIDR is in `monitoring_whitelist`.
- **Event type:** the operator's webhook fires on **merge_request + note** events
  (`push_events:false`), so the e2e trigger is opening an MR, not a bare push.
- **Verified:** MR → webhook (HTTPS 202) → `edp-gitlab` EL → gitlab interceptor →
  `gitlab-review` TriggerTemplate → PipelineRun `review-test-go-app-main-*` →
  recorded in Tekton Results (`results.tekton.dev/record`). The runs then fail
  fast (no registry; status-report task mis-parses the SSH URL) — out of scope.

## Container registry (reuse GitLab's) — verified 2026-05-31

Reused GitLab's bundled Container Registry as KRCI's image registry:
- **Enable** (manifests/gitlab.yaml): `registry['enable']=true`,
  `registry_external_url 'https://gitlab.127.0.0.1.nip.io:5050'`,
  `registry_nginx` ssl cert = the gitlab-tls cert; svc exposes 5050. In-cluster
  build pods reach it via the existing CoreDNS rewrite (gitlab host → gitlab svc).
- **KRCI has no "gitlab" registry type** (only ecr/harbor/dockerhub/openshift/
  nexus/ghcr). Declared as **harbor** (generic private registry): kaniko pushes
  `<url>/<space>/<codebase>`. With `space=krci` the image is `…/krci/<codebase>`,
  which maps to that codebase's own GitLab project registry — clean alignment.
- **Auth**: a `krci`-group **deploy token** (read+write registry) → secret
  `kaniko-docker-config` (dockerconfigjson, mounted at /kaniko/.docker). GitLab
  registry uses Bearer/JWT, so a plain `curl -u /v2/` returns 401 — verify via
  `/jwt/auth?service=container_registry&scope=repository:<path>:push,pull`.
- **TLS**: kaniko trusts the self-signed registry via `edp-tekton.kaniko.customCert=true`
  (flips `custom_certs=true`; adds `--registry-certificate <url>=/kaniko/.custom-certs/ca.crt`
  from secret `custom-ca-certificates`, key `ca.crt`).
- **Config**: `global.dockerRegistry` (type/url/space) → `krci-config`
  (container_registry_host/space/type) read by the kaniko task.
- **Verified**: a TaskRun of the real `kaniko` task built+pushed
  `gitlab…:5050/krci/test-go-app:registry-smoke` (visible in the project registry);
  Codebase branches now pass the `put_codebase_image_stream` step.
- **Status reporting (fixed)**: the `gitlab-set-status` task mis-parsed our
  `ssh://…:32222/…` URL (host `ssh`) and verified TLS against the self-signed cert.
  scripts/gitlab.sh patches its script (scripts/gitlab-set-status.py) to extract the
  host from any URL form + skip TLS verify. Verified: `report-pipeline-start-to-gitlab`
  now succeeds and the build chain runs through `container-build`. Patch survives
  `make krci` (helm 3-way merge).
- **Remaining for fully-green PipelineRun**: the `sonar` task needs a `ci-sonarqube`
  secret (a SonarQube instance, not deployed) → `CreateContainerConfigError`. And
  GitLab may deliver the MR webhook twice → two concurrent runs; the duplicate gets
  a 400 posting the same commit-status context.

## Files touched (expected)

- `values/edp-install.yaml` — add `gitlab` to gitProviders.
- `manifests/gitlab.yaml` — already present; maybe trim resources.
- `scripts/gitlab.sh` — update GitServer CR + webhook URL to the verified path;
  add the EventListener-readiness check.
- `Makefile` — `gitlab` target exists; maybe add `gitlab-status` / webhook test.
- `README.md` — promote GitLab from "phase 2, untested" to documented once green.
