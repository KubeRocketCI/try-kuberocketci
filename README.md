# krci-k8s — local KubeRocketCI test bed

Spin up [KubeRocketCI](https://docs.kuberocketci.io) (release **3.13.5**) inside a
local `kind` cluster on Docker Desktop, add **Prometheus** + **Tekton Results**
for a full test bed, run the **Portal from source** against it, and optionally a
self-hosted **GitLab** wired for webhook-triggered pipelines (`make gitlab`).
Component versions are pinned to what the GitOps source of
truth ([edp-cluster-add-ons](https://github.com/epam/edp-cluster-add-ons)) ships,
but installed directly with helm/kubectl instead of Argo CD — so you can stand the
platform up with a couple of commands and poke at any component.

## Prerequisites

- Docker Desktop with **≥ 8 GB RAM** (the full test bed is comfortable at 8–10 GB;
  the GitLab phase wants several GB more).
- `kind`, `helm`, `kubectl` on PATH (`make tools` installs `kind` via brew).

## Quick start

Spin up the whole platform from scratch, three commands (each is idempotent and
independently re-runnable):

```bash
make testbed     # ~10-15 min: kind + ingress + cert-manager + Tekton + KRCI + Prometheus + Results
make gitlab      # ~6-8 min:  self-hosted GitLab + registry + GitServer + GitOps repo + webhook wiring
make e2e         # ~4 min:    triggers a review pipeline; PASS = green except the sonar task
```

Then optionally:

```bash
make status      # cluster + KRCI + capabilities overview
make token       # mint a 24h login token for the Portal (run from source — see below)
```

`make down` tears the whole cluster back down. A full from-zero validation is
exactly: `make down && make testbed && make gitlab && make e2e`.

> `make e2e` ends **green except `sonar`** on purpose — the review/build pipelines
> include a SonarQube quality-gate task and SonarQube is **not** deployed here.
> Deploying it is the documented **next phase**.

## What `make testbed` brings up

| Layer | Component | Version | Namespace |
|---|---|---|---|
| Cluster | kind (k8s) | v1.35.0 | — |
| Ingress | ingress-nginx | controller-v1.11.3 | ingress-nginx |
| Certs | cert-manager | v1.16.2 | cert-manager |
| CI engine | Tekton Pipelines / Triggers | v1.6.0 / v0.34.0 | tekton-pipelines |
| Platform | KubeRocketCI (edp-install) | 3.13.5 | krci |
| Monitoring | kube-prometheus-stack (+Grafana) | 84.5.0 | monitoring |
| Run storage | Tekton Results (+ minimal Postgres) | v0.17.2 | tekton-pipelines |

KRCI core pods (ns `krci`): `cd-pipeline-operator`, `codebase-operator`,
`gitfusion`, `tekton-cache`, `tekton-interceptor`. The in-cluster Portal is
intentionally disabled — run it from source (below).

## Targets

Run `make help` for the full list. Build it up piecemeal or all at once:

```bash
make up            # core only: cluster -> ingress -> cert-manager -> tekton -> krci
make prometheus    # add kube-prometheus-stack + Grafana
make tekton-results# add Tekton Results v0.17.2 + its minimal Postgres
make testbed       # = up + prometheus + tekton-results

make token         # 24h cluster-admin bearer token (Portal login)
make results-forward  # port-forward Tekton Results API to localhost:8080
make status        # cluster + KRCI + capabilities overview
make krci-dry-run  # render the edp-install chart without installing
make argocd        # (optional) Argo CD for CD/deploy stages
make gitlab        # self-hosted GitLab + GitServer + webhook wiring (see below)
make gitlab-status # show GitLab pod / GitServer / EventListener / webhook state
make e2e           # trigger a review pipeline; PASS = green except sonar
make down          # delete the kind cluster
```

Each capability target is independent and idempotent, so you can rebuild or debug
one component (e.g. `make tekton-results`) without touching the rest.

## Portal (run from source)

The in-cluster Portal image is disabled; run the Portal from a separate
`krci-portal` checkout at `../portal/krci-portal`:

```bash
# one-time: .env / .env.development + apps/server/db already set up in that repo
make token                              # copy the JWT
cd ../portal/krci-portal && pnpm dev    # http://localhost:5173
```

Open http://localhost:5173 → **Sign In with Token** → paste the token. (Auth uses
a local dev OIDC bypass patched into the portal's `loginWithToken` procedure, so
the kube ServiceAccount token is accepted directly — no real IdP needed.)

To light up the Portal's PipelineRun history (Tekton Results), point the Portal at
the Results ingress (`make tekton-results` provisions it — no port-forward needed):

```bash
# krci-portal/.env:
TEKTON_RESULTS_URL=http://tekton-results.127.0.0.1.nip.io
```

`make results-forward` (localhost:8080) is still available as a fallback.

## Self-hosted GitLab + webhook integration (`make gitlab`)

Deploys a single-pod GitLab CE into the cluster and wires it so a GitLab **merge
request** triggers a KubeRocketCI Tekton pipeline through the edp-tekton GitLab
EventListener + `gitlab` ClusterInterceptor.

```bash
# prerequisite: gitlab is in global.gitProviders in values/edp-install.yaml
# (already set here) so edp-tekton renders the gitlab TriggerBindings/Templates.
make gitlab          # deploy GitLab, bootstrap creds, register the GitServer
make gitlab-status   # check it came up green
```

What it sets up (all in `scripts/gitlab.sh`, idempotent):

1. **GitLab CE** (`manifests/gitlab.yaml`) — one omnibus pod, exporters/registry/KAS
   off, Puma single-mode. Data + `/etc/gitlab` (secrets) on PVCs.
2. **TLS** — GitLab serves **HTTPS** with a self-signed cert (secret `gitlab-tls`).
   This is required: the codebase-operator's GitLab API client only speaks https
   (the GitServer CRD has just `httpsPort`). The operator is patched to trust that
   CA (mounted into `/etc/ssl/certs`).
3. **CoreDNS split-horizon** — `gitlab.127.0.0.1.nip.io` → GitLab svc (for the
   operator's API/SSH), and the EventListener ingress host → ingress-nginx (so
   GitLab can POST webhooks in-cluster). The browser still reaches both at
   `localhost` via the kind ingress.
4. **Credentials** — root PAT, SSH key, and a webhook secret, stored in the `krci`
   secret `ci-gitlab` (keys `token` / `username` / `id_rsa` / `secretString`).
5. **GitServer CR** `gitlab` (no `webhookUrl`), which makes the codebase-operator
   create EventListener `edp-gitlab` + its ingress automatically.
6. **A `krci` group** in GitLab — Codebases live under `krci/<repo>` (set
   `gitUrlPath: /krci/<repo>`) instead of root's personal namespace.
7. **The GitOps repo** `krci/krci-gitops` (`manifests/krci-gitops.yaml`) — a
   `system`/`helm`/`gitops` Codebase (labels `app.edp.epam.com/codebaseType=system`
   + `systemType=gitops`), which KubeRocketCI requires before Deployments/CD
   pipelines.
8. **Container registry** — enables GitLab's registry and points KRCI at it
   (see below), plus the `kaniko-docker-config` + `custom-ca-certificates` secrets.

End-to-end test (`manifests/sample-codebase.yaml`):

```bash
kubectl apply -f manifests/sample-codebase.yaml   # Codebase test-go-app (go/gin)
# operator creates GitLab project krci/test-go-app + a project webhook -> el-gitlab-krci...
# open an MR in krci/test-go-app -> a review PipelineRun starts in ns krci and
# is recorded in Tekton Results (results.tekton.dev/record annotation).
```

### Container registry (reuse GitLab's)

`make gitlab` also enables GitLab's **Container Registry** (on `:5050`, same
self-signed cert) and points KubeRocketCI at it, so build pipelines push images to
`gitlab.127.0.0.1.nip.io:5050/krci/<codebase>` — i.e. each codebase's own GitLab
project registry. Wiring:

- `manifests/gitlab.yaml`: `registry['enable']=true`, `registry_external_url …:5050`, svc port 5050.
- `values/edp-install.yaml`: `global.dockerRegistry` (`type: harbor`, `url: …:5050`, `space: krci`) → kaniko pushes `<url>/<space>/<codebase>`; and `edp-tekton.kaniko.customCert: true` so kaniko trusts the self-signed registry cert.
- `scripts/gitlab.sh`: mints a `krci`-group **deploy token** (read+write registry) → secret `kaniko-docker-config`; copies the CA → secret `custom-ca-certificates`.

Verified: the `kaniko` task builds and pushes to `krci/test-go-app` (image visible
under the project's Container Registry), and Codebase branches now provision past
the image-stream step.

**Pipeline status reporting (fixed):** the stock edp-tekton `gitlab-set-status` task
mis-parsed our `ssh://…:32222/…` git URL (posting to host `ssh`) and verified TLS
against the self-signed cert, so every PipelineRun aborted at
`report-pipeline-start-to-gitlab`. `scripts/gitlab.sh` patches the task's script
(`scripts/gitlab-set-status.py`) to extract the host from any URL form and skip TLS
verification — the task now reports commit status to GitLab and the build chain
runs through `container-build` (kaniko). The patch survives `make krci` (helm's
3-way merge only resets fields the chart itself changes).

**Remaining for a fully green PipelineRun:** the review/build pipelines include a
`sonar` task that requires a `ci-sonarqube` secret (a **SonarQube** instance, not
deployed here) → it fails with `CreateContainerConfigError`. Also, GitLab can
deliver the MR webhook twice, creating two concurrent runs; the second gets a `400`
posting the same commit-status context (harmless duplicate).

## Layout

```
Makefile                                # all orchestration (make help)
kind/cluster.yaml                       # single-node kind, ports 80/443 -> localhost
values/edp-install.yaml                 # KubeRocketCI chart values (in-cluster portal off)
values/kube-prometheus-stack.yaml       # Prometheus + Grafana values
manifests/tekton-results.yaml           # canonical KRCI Results manifest (verbatim from add-ons)
manifests/tekton-results-postgres.yaml  # minimal Postgres backing Results
manifests/tekton-results-ingress.yaml   # ingress: Results API at tekton-results.<wildcard>
manifests/gitlab.yaml                   # self-hosted GitLab CE (HTTPS, single pod)
manifests/sample-codebase.yaml          # e2e: Codebase+branch that exercises the webhook
manifests/krci-gitops.yaml              # KubeRocketCI GitOps repo (system/helm codebase)
scripts/gitlab.sh                       # deploy GitLab + creds + GitServer + group + gitops + webhook
scripts/gitlab-set-status.py            # corrected gitlab-set-status task script (host parse + TLS)
```

## Notes & decisions

- **DNS:** `nip.io` wildcard (`*.127.0.0.1.nip.io`) maps every ingress host to
  localhost — no `/etc/hosts` edits.
- **Tekton webhook race:** the `tekton` target waits for the pipelines/triggers
  *webhooks* (not just controllers) before KRCI applies its Pipeline CRs —
  otherwise the helm install fails with `connection refused` on
  `webhook.pipeline.tekton.dev`.
- **Tekton Results** uses a single stock `postgres:16-alpine` (Crunchy PGO
  intentionally not installed). It satisfies the canonical manifest's DB contract
  exactly (service `results-primary`, db `results`, secret `results-pguser-results`),
  so that manifest is used unmodified except for pinning the `logs` PVC namespace.
  `AUTH_DISABLE=true` and TLS off (local only). `ns tekton-pipelines` enforces
  PodSecurity `restricted`, so the Postgres pod ships a compliant securityContext.
- **Auth:** SSO/Keycloak is not deployed; the Portal uses a Kubernetes bearer
  token (`make token`, cluster-admin, 24h — local testing only).
- **Git provider:** KubeRocketCI supports gitlab/github/gerrit/bitbucket — **not
  Gitea** — so the self-hosted option is GitLab (`make gitlab`, documented above).
- **Versions** are pinned at the top of the `Makefile` (`EDP_VERSION`,
  `PROM_CHART_VERSION`, the Tekton URLs, etc.). Bump there to upgrade.
- **Deferred:** Keycloak/OIDC is not deployed; a container registry for green
  builds is not configured (`global.dockerRegistry` empty).
```
