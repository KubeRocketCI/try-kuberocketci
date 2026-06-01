# Self-hosted GitLab + edp-tekton webhook integration

How a Merge Request in the in-cluster, self-hosted GitLab triggers a KubeRocketCI
Tekton pipeline through the **edp-tekton GitLab EventListener** and the **`gitlab`
ClusterInterceptor**. This documents how the integration is wired in this repo.

For the broader install design, see [architecture.md](architecture.md).

## The webhook path

```
GitServer CR + ci-gitlab secret
        │  (codebase-operator reconciles)
        ▼
GitLab project webhook  ──HTTPS──▶  edp-gitlab EventListener (ingress)
                                            │
                                   gitlab ClusterInterceptor
                                   (validates X-Gitlab-Token, filters events)
                                            │
                                   TriggerTemplate (review | build)
                                            ▼
                                   Tekton PipelineRun  ──▶ Tekton Results
```

In words: the **codebase-operator** creates a per-project webhook in GitLab using
the `GitServer` + token. GitLab POSTs MR/note events to the EventListener's ingress
host. The `gitlab` ClusterInterceptor validates the `X-Gitlab-Token` shared secret
and filters event types; the matching `Trigger` spawns the PipelineRun.

## How the integration is wired

The load-bearing details:

- **The EventListener is created per-GitServer by the codebase-operator, not by
  `gitProviders`.** Adding `gitlab` to `global.gitProviders` only renders the
  gitlab `TriggerBinding`/`TriggerTemplate` resources. The EventListener
  (`edp-gitlab`), its Ingress (`event-listener-gitlab`, host
  `el-gitlab-krci.<wildcard>`), and Service (`el-edp-gitlab:8080`) are created when
  the GitServer's `spec.webhookUrl` is left empty.

- **One secret carries everything.** The `nameSshKeySecret` secret (`ci-gitlab`)
  holds `token`, `username`, `id_rsa`, and **`secretString`** — the latter is the
  webhook `X-Gitlab-Token` the ClusterInterceptor validates. The operator sets the
  same value as the webhook token in GitLab. There is **no** per-EventListener
  secret.

- **HTTPS is mandatory.** The operator's GitLab REST client always uses `https://`
  (the `GitServer` CRD exposes only `httpsPort`). HTTP-only GitLab fails with
  *"server gave HTTP response to HTTPS client."* GitLab therefore serves TLS with a
  self-signed cert (`secret/gitlab-tls`), and the operator is **patched to trust
  that CA** (mounted into its trust store). `skipWebhookSSLVerification` covers only
  webhooks, **not** the API client — the CA mount is required.

- **SSH on a fixed port.** The GitLab Service exposes `32222 → 22`; the operator's
  SSH connection check and clones dial `gitHost:32222`.

- **GitLab blocks local-network webhooks by default.** It is enabled
  programmatically via the application setting
  `allow_local_requests_from_web_hooks_and_services = true`.

- **Trigger events.** The operator's webhook fires on **merge_request + note**
  events (`push_events: false`). So the trigger is opening/updating/merging an MR,
  not a bare push.

## The review / build split

Two `Trigger` CRs on the EventListener split the lifecycle by MR action:

| Trigger | Fires on | Result |
|---|---|---|
| `gitlab-review` | MR `open` / `reopen` / `update` (+ note hooks) | review PipelineRun (lint, test, **sonar**) |
| `gitlab-build` | MR action `merge` | build PipelineRun (kaniko push, image stream update) |

So **merging the MR — not a separate push — kicks the build**. The path is:
MR → webhook → `edp-gitlab` EventListener → gitlab interceptor → review PipelineRun,
recorded in Tekton Results.

## GitLab omnibus configuration notes

Running GitLab CE as a single omnibus pod inside `kind` requires several non-obvious
settings:

- `grafana['enable']` was removed in omnibus 16.0+ and breaks `gitlab-ctl
  reconfigure` if set — leave it out.
- `/etc/gitlab` **must** be on a PVC — it holds the DB encryption keys, so without
  it a restart rotates the secrets and breaks the database.
- `progressDeadlineSeconds` must be raised (first boot is slow) so the Deployment
  rollout doesn't trip `rollout status`.
- `/-/health` is blocked for the kubelet's probe source unless the pod network is
  added to GitLab's `monitoring_whitelist`.

## Container registry: reuse GitLab's bundled registry

GitLab's own Container Registry doubles as KRCI's image registry, avoiding a
separate Harbor/Nexus:

- **Enabled** in `manifests/gitlab.yaml`: `registry['enable'] = true`,
  `registry_external_url 'https://gitlab.127.0.0.1.nip.io:5050'`, registry nginx
  using the `gitlab-tls` cert; the Service exposes `5050`. In-cluster build pods
  reach it via the CoreDNS rewrite (gitlab host → gitlab svc).
- **Registry type:** KRCI has no "gitlab" type (only ecr/harbor/dockerhub/
  openshift/nexus/ghcr), so it's declared as **harbor** (generic private registry).
  kaniko pushes `<url>/<space>/<codebase>`; with `space=krci` the image is
  `…/krci/<codebase>`, mapping to that codebase's own GitLab project registry.
- **Auth:** a `krci`-group **deploy token** (read+write registry) →
  `secret/kaniko-docker-config` (`dockerconfigjson`, mounted at `/kaniko/.docker`).
- **TLS:** kaniko trusts the self-signed registry via
  `edp-tekton.kaniko.customCert = true` (reads the CA from
  `secret/custom-ca-certificates`).
- **Config plumbing:** `global.dockerRegistry` (type/url/space) flows into
  `krci-config` (`container_registry_host`/`space`/`type`), read by the kaniko task.

## Status reporting fix

The stock `gitlab-set-status` task mis-parsed the `ssh://…:32222/…` git URL (host
became `ssh`) and verified TLS against the self-signed cert, so
`report-pipeline-start-to-gitlab` failed on every run. `scripts/gitlab-set-status.py`
patches the task to extract the host from any URL form and skip TLS verification.
The patch is re-applied by `gitlab-integrate` because Helm SSA resets the task on
each `make krci` (see [architecture.md](architecture.md#the-tekton-task-patches-and-the-helm-ssa-race)).

## Related files

| File | Role |
|---|---|
| `manifests/gitlab.yaml` | Self-hosted GitLab CE (HTTPS, single pod, registry on `:5050`) |
| `scripts/gitlab-up.sh` | Pre-KRCI: deploy GitLab + bootstrap creds/secrets + CoreDNS |
| `scripts/gitlab-integrate.sh` | Post-KRCI: CA trust + task patch + GitOps repo |
| `scripts/gitlab-set-status.py` | Corrected `gitlab-set-status` task script |
| `values/edp-install.yaml` | `edp-tekton.gitServers.gitlab`, registry, kaniko CA |
