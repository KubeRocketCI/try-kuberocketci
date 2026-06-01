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

Spin up the whole platform from scratch, two commands:

```bash
make testbed     # ~18-20 min: all dependencies first, then KRCI installed LAST with values
make e2e         # ~12 min:    MR -> review -> merge -> build -> deploy (demo/dev); PASS = all green + app deployed
```

`make testbed` builds in dependency order and installs the KRCI platform last so the
chart can wire itself to what's already up:

```
cluster → ingress → cert-manager → Tekton → Argo CD → Prometheus → Tekton Results → SonarQube
        → gitlab-up   (deploy GitLab + bootstrap creds/secrets)        [bash]
        → krci        (edp-install; renders GitServer/EventListener/Ingress + registry from values)
        → gitlab-integrate  (operator CA trust + gitlab-set-status fix + GitOps repo)  [bash]
        → argocd-integrate  (repo creds + known-hosts + ci-argocd secret)              [bash]
        → sonar-integrate   (mint token + ci-sonarqube secret in ns krci)             [bash]
```

Then optionally:

```bash
make status      # cluster + KRCI + capabilities overview
make token       # mint a 24h login token for the Portal (run from source — see below)
```

`make down` tears the whole cluster back down. A full from-zero validation is
exactly: `make down && make testbed && make e2e`.

> `make testbed` now deploys **SonarQube** + the `ci-sonarqube` integration secret
> (`make sonar` / `sonar-integrate`), so the review pipeline's `sonar` task can run
> instead of erroring on a missing secret. See "SonarQube (code quality)" below.

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
| CD engine | Argo CD (single instance) | chart 9.5.17 / v3.4.3 | argocd |
| Code quality | SonarQube (+ own Postgres, sonar-operator) | chart 2025.3.1 / 25.5-community | sonar |

KRCI core pods (ns `krci`): `cd-pipeline-operator`, `codebase-operator`,
`gitfusion`, `tekton-cache`, `tekton-interceptor`. The in-cluster Portal is
intentionally disabled — run it from source (below).

## Credentials (local only)

> ⚠️ **LOCAL USE ONLY.** These are fixed, predictable credentials baked into this
> testbed for convenience on a throwaway `kind` cluster. They are **not secret** and
> **must never** be used on any shared, internet-reachable, or production cluster.
> Everything here serves over plain HTTP / self-signed TLS with no real SSO.

The web UIs come up with predictable credentials so logins are repeatable across
`make down && make testbed`. Each is also printed by its `make *-password` target and
echoed in `make status`:

| Component | URL | User | Password | Override / retrieve |
|---|---|---|---|---|
| GitLab | https://gitlab.127.0.0.1.nip.io | `root` | `KrciLocal_2026!` | `make GITLAB_ROOT_PASSWORD=… gitlab-up` · `make gitlab-password` |
| SonarQube | http://sonar.127.0.0.1.nip.io | `admin` | `KrciSonar_2026!` | `manifests/sonar-admin-secret.yaml` · `make sonar-password` |
| Argo CD | http://argocd.127.0.0.1.nip.io | `admin` | _(chart-generated)_ | `make argocd-password` |
| Grafana | _(port-forward)_ | `admin` | `prom-operator` | `values/kube-prometheus-stack.yaml` |

The **GitLab root password** is set predictably via the `GITLAB_ROOT_PASSWORD` Makefile
var (default `KrciLocal_2026!`) → secret `gitlab-root-password` → the omnibus
`gitlab_rails['initial_root_password']`. It is seeded on the **first** GitLab install;
on an existing data PVC it's a no-op (reset with `gitlab-rake "gitlab:password:reset[root]"`).
If you override it, note GitLab 17.x rejects passwords containing the app name (`gitlab`)
or the username (`root`) as "commonly used". The Portal itself uses a 24h Kubernetes
bearer token, not a password — see below.

## Targets

Run `make help` for the full list. Build it up piecemeal or all at once:

```bash
make up            # prerequisites only: cluster -> ingress -> cert-manager -> tekton -> argocd (no KRCI)
make prometheus    # add kube-prometheus-stack + Grafana
make tekton-results# add Tekton Results v0.17.2 + its minimal Postgres
make sonar         # install SonarQube (chart 2025.3.1) + own Postgres + sonar-operator + CRs
make argocd        # install Argo CD (single instance, chart 9.5.17) + krci AppProject
make krci          # install KubeRocketCI (renders GitServer/EL from values; run gitlab-up first)
make testbed       # full platform: up + prometheus + results + gitlab-up + krci + gitlab-integrate + argocd-integrate

make token         # 24h cluster-admin bearer token (Portal login)
make results-forward  # port-forward Tekton Results API to localhost:8080
make status        # cluster + KRCI + capabilities overview
make krci-dry-run  # render the edp-install chart without installing
make argocd-integrate # (post-krci) repo creds + known-hosts + ci-argocd secret + deploy task fix
make argocd-password  # print the Argo CD initial admin password
make sonar-integrate  # (post-krci) mint token + ci-sonarqube secret in ns krci
make sonar-password   # print the SonarQube admin credentials (local default)
make gitlab-up        # (pre-krci) deploy GitLab + bootstrap creds/secrets + CoreDNS
make gitlab-integrate # (post-krci) operator CA trust + gitlab-set-status fix + GitOps repo
make gitlab-password  # print the GitLab root credentials (local default)
make gitlab-status    # show GitLab pod / GitServer / EventListener / webhook state
make e2e              # MR -> review -> merge -> build -> deploy (demo/dev); PASS = all green + app deployed
make down             # delete the kind cluster
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

For **repository discovery** (listing GitLab groups/projects/branches/PRs when you
onboard a Codebase), the Portal calls **gitfusion**. The chart now renders a
gitfusion ingress (`gitfusion.ingress` in `values/edp-install.yaml`), so point the
Portal at it — same idea as the Results URL:

```bash
# krci-portal/.env:
GITFUSION_URL=http://gitfusion.127.0.0.1.nip.io
```

> gitfusion talks to GitLab over **HTTPS with the self-signed cert**, so it must
> trust the GitLab CA. The chart mounts `cm gitlab-ca` into gitfusion declaratively
> (`gitfusion.volumes`/`volumeMounts` in `values/edp-install.yaml`), applied at
> `make krci` time — so it trusts the CA on first start. Without it, discovery fails
> with x509 "unknown authority" even though the URL is reachable.

For the **Stage Monitoring** tab (deployment metrics), the Portal queries
**Prometheus**. `make prometheus` renders an ingress (`prometheus.ingress` in
`values/kube-prometheus-stack.yaml`), so point the Portal at it:

```bash
# krci-portal/.env:
PROMETHEUS_URL=http://prometheus.127.0.0.1.nip.io
```

`make status` prints all three (`TEKTON_RESULTS_URL`, `GITFUSION_URL`,
`PROMETHEUS_URL`) under "portal env" so you can copy them straight into `.env`.

## Self-hosted GitLab + webhook integration

A single-pod GitLab CE is wired so a GitLab **merge request** triggers a
KubeRocketCI Tekton pipeline through the edp-tekton GitLab EventListener +
`gitlab` ClusterInterceptor. GitLab is a **platform dependency**: it comes up
*before* `make krci`, and the **GitServer / EventListener / Ingress are rendered by
the chart** from `edp-tekton.gitServers` in `values/edp-install.yaml` — not created
imperatively. `make testbed` runs the phases in order; the GitLab-specific bash is
split into `gitlab-up` (pre-krci) and `gitlab-integrate` (post-krci). See
`docs/gitlab-declarative-refactor.md` for the rationale.

**`gitlab-up`** (`scripts/gitlab-up.sh`, before krci):

1. **GitLab CE** (`manifests/gitlab.yaml`) — one omnibus pod, exporters/KAS off,
   Puma single-mode, Container Registry on `:5050`. Data + `/etc/gitlab` on PVCs.
2. **TLS** — GitLab serves **HTTPS** with a self-signed cert (secret `gitlab-tls`);
   required because the operator's GitLab API client only speaks https.
3. **CoreDNS split-horizon** — `gitlab.127.0.0.1.nip.io` → GitLab svc; EventListener
   host `el-gitlab-krci.127.0.0.1.nip.io` → ingress-nginx (deterministic, added up front).
4. **Credentials/secrets in ns `krci`** — `ci-gitlab` (token/username/id_rsa/secretString,
   referenced by `gitServers`), `kaniko-docker-config` (group deploy token for the
   registry), `custom-ca-certificates` + cm `gitlab-ca` (the self-signed CA).
5. **A `krci` group** — Codebases live under `krci/<repo>`.

**`make krci`** then renders, from values: the **GitServer `gitlab`**, **EventListener
`edp-gitlab`**, its **Ingress**, the gitlab pipelines, and the registry config in
`krci-config`. Because `ci-gitlab` already exists, the GitServer connects on first
reconcile (no EL-creation race).

**`gitlab-integrate`** (`scripts/gitlab-integrate.sh`, after krci) — only what the
chart can't express:

6. **operator CA trust** — mount cm `gitlab-ca` into codebase-operator (no chart hook).
7. **`gitlab-set-status` fix** — patch the upstream task (host parse + self-signed TLS).
8. **GitOps repo** `krci/krci-gitops` (`manifests/krci-gitops.yaml`) — a
   `system`/`helm`/`gitops` Codebase KubeRocketCI requires before Deployments.

End-to-end test — `make e2e` (`scripts/e2e.sh`) drives the **whole CI→CD lifecycle**
fully automated (no UI), and `manifests/sample-codebase.yaml` is the codebase it
exercises:

```bash
make e2e   # Codebase test-go-app (go/gin), then:
# 1. operator creates GitLab project krci/test-go-app + a project webhook -> el-gitlab-krci...
# 2. open an MR             -> review PipelineRun  -> assert fully green (incl. sonar)
# 3. merge the MR (action=merge fires the gitlab-build trigger)
#                           -> build  PipelineRun  -> assert fully green; kaniko pushes the image
# 4. read the built tag from CodebaseImageStream test-go-app-main
# 5. create CDPipeline "demo" + Stage "dev" (manifests/cdpipeline-demo.yaml)
# 6. CDStageDeploy that exact tag -> deploy PipelineRun -> Argo CD syncs the
#    deploy-templates Helm chart into ns krci-demo-dev; assert the workload is
#    Available on the built tag.
# All PipelineRuns are recorded in Tekton Results (results.tekton.dev/record annotation).
```

The review/build trigger split lives in the EventListener `Trigger` CRs: `gitlab-review`
fires on MR `open/reopen/update` (+ note hooks), `gitlab-build` on MR action `merge`.
So merging the MR — not a separate push — is what kicks the build.

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

## Argo CD (CD engine)

KubeRocketCI uses Argo CD for CD/deploy: the `cd-pipeline-operator` creates Argo CD
`Application` CRs in the `krci` namespace and talks to Argo CD via an `argocd-ci`
integration secret. Argo CD is installed as a **prerequisite** (in `make up`, after
Tekton) from the community Helm chart, then wired to KRCI post-install — the same
**baseline → integrate** split as GitLab.

**`make argocd`** (baseline, in `up`): `helm upgrade --install argocd argo/argo-cd`
(chart `9.5.17`) with `values/argo-cd.yaml`, then applies the `krci` **AppProject** and
the **appset RBAC hack** (below). Mostly single-instance (dex/notifications off, single
Redis), but the **ApplicationSet controller runs** (1 replica) because KRCI's CD deploy
depends on it. The KRCI-critical knobs in `configs.params`:
- `application.namespaces: krci` + `applicationsetcontroller.namespaces: krci` — KRCI
  creates the `Application`/`ApplicationSet` in the `krci` namespace, so both controllers
  must watch it (apps-in-any-namespace).
- `applicationsetcontroller.enable.scm.providers: "false"` — required, or the appset
  controller refuses to start once appset-namespaces is set.

Served over HTTP (`server.insecure`, matching edp-cluster-add-ons) behind an ingress at
`argocd.127.0.0.1.nip.io`. `make argocd-password` prints the admin password.

> **Appset RBAC hack** (`manifests/argocd-appset-rbac.yaml`): apps-in-any-namespace needs
> the appset controller to list/manage `applications`/`applicationsets`/`appprojects` at
> *cluster* scope, which the chart doesn't grant. Verbatim from the add-ons `rbac-hack`
> (plus `appprojects` for Argo CD v3.4.x).

**`make argocd-integrate`** (post-krci, `scripts/argocd-integrate.sh`):

1. **Repo credentials** — a `repo-creds` secret (`gitlab-creds`, ns `argocd`) from the
   same `ci-gitlab` SSH key, for `ssh://git@gitlab.<wildcard>:32222/`.
2. **Known hosts** — GitLab's host key added to `argocd-ssh-known-hosts-cm` so the
   repo-server passes SSH host-key verification.
3. **`ci-argocd` secret** (ns `krci`) — a non-expiring `krci-ci` API token + `url`
   (`http://argocd-server.argocd.svc:80`), labelled `integration-secret`/`secret-type: argocd`.
   This is what the edp-tekton **deploy** task reads (note the name is `ci-argocd`, the
   `ci-<provider>` convention — not `argocd-ci`).
4. **`--plaintext` patch** — the stock `deploy-applicationset-cli` task's `argocd` CLI
   defaults to TLS but our server is plaintext; the script adds `--plaintext` to
   `ARGOCD_OPTS` (survives `make krci`, like the gitlab-set-status fix).

   The GitLab host key is injected **through helm** (`configs.ssh.extraHosts`, via a
   targeted `helm upgrade`) rather than patched into `argocd-ssh-known-hosts-cm`
   directly — the chart server-side-owns that field, so a direct edit makes the next
   `make argocd` upgrade fail with a field-ownership conflict. Caveat: a standalone
   `make argocd` re-run resets `extraHosts` (drops the GitLab host); just re-run
   `make argocd-integrate` to restore it (no error either way).

**How a deploy flows** (verified end-to-end — Application `Synced`/`Healthy`): a CD
`Stage` reconcile (cd-pipeline-operator) creates the per-stage configmap + an Argo CD
`ApplicationSet` in `krci`; the deploy pipeline's `pre-deploy`/`deploy-app` tasks fill the
appset generator with the chosen image tag; the appset controller generates the
`Application`; Argo CD syncs the codebase's `deploy-templates` Helm chart into
`krci-<pipeline>-<stage>`.

Two things this depends on that aren't obvious:
- **`regcred`** (registry **pull** secret, ns `krci`) — the Stage reconcile copies it into
  the deploy namespace as the workload `imagePullSecret`; without it the Stage fails
  (`failed to get regcred secret`) and the deploy pipeline can't find the per-stage
  configmap. Created by `scripts/gitlab-up.sh` (same GitLab registry creds as kaniko).
- **kind containerd registry mirror** — deployed pods pull
  `gitlab.<wildcard>:5050/...`, but containerd on the node resolves that to `127.0.0.1`
  (the CoreDNS rewrite only helps in-cluster pods). `kind/cluster.yaml` enables
  `config_path` and `gitlab-up.sh` drops a `hosts.toml` mirroring the registry host to the
  GitLab service ClusterIP (`skip_verify`), so `kubelet`/containerd can pull.

## SonarQube (code quality)

The review/build pipelines include a `sonar` quality-gate task that needs a SonarQube
instance + a `ci-sonarqube` integration secret. SonarQube is installed as a capability
(mirroring `edp-cluster-add-ons/.../sonar` + `sonar-operator`), then wired to KRCI —
same **install → integrate** split as GitLab/Argo CD.

**`make sonar`** (capability): our own minimal **Postgres** (`manifests/sonar-postgres.yaml`,
the Tekton Results pattern — fulfils the add-ons `sonar-primary` / `sonar-pguser-sonar`
DB contract) → **SonarQube** Helm chart `2025.3.1` (`values/sonarqube.yaml`, the add-ons
values flattened to top level, community edition + branch plugin, **external** jdbc to our
Postgres) → **edp-sonar-operator** `3.3.0` + its CRs (`manifests/sonar-operator-crs.yaml`:
`Sonar`, `SonarGroup`s, `SonarPermissionTemplate` `edp-default`, `SonarQualityGate`
`edp-way`, `SonarUser` `ci-user`). UI at `http://sonar.127.0.0.1.nip.io` (user `admin`;
`make sonar-password`).

> Three non-obvious bits: the chart **requires `monitoringPasscode`** or the pod never
> becomes Ready; we use our **own Postgres** (`postgresql.enabled: false` +
> `jdbcOverwrite`) rather than the chart's deprecated bundled one or Crunchy PGO; and the
> chart's **`setAdminPassword` hook** changes the default `admin/admin` to the password in
> `manifests/sonar-admin-secret.yaml` on first startup, so the forced first-login password
> change is automated (the operator + integrate script authenticate with that same secret).

**`make sonar-integrate`** (post-krci, `scripts/sonar-integrate.sh`): mints a SonarQube
token for the operator-created `ci-user` via the API and creates secret **`ci-sonarqube`**
in ns `krci` (`url` = `http://sonar.sonar.svc:9000`, `token`, labels
`app.edp.epam.com/secret-type: sonar` + `integration-secret: "true"`) — what the edp-tekton
`sonar` task reads.

> **RAM:** SonarQube (embedded Elasticsearch + JVM, ~1.5Gi req / 3Gi limit) plus its
> Postgres is heavy. With GitLab also running (~12Gi), give Docker well above 8Gi. The
> full plugin list downloads at pod start, so the first `make sonar` rollout is slow
> (900s timeout).

## Layout

```
Makefile                                # all orchestration (make help)
kind/cluster.yaml                       # single-node kind, ports 80/443 -> localhost
values/edp-install.yaml                 # KubeRocketCI chart values (in-cluster portal off)
values/kube-prometheus-stack.yaml       # Prometheus + Grafana values
values/argo-cd.yaml                      # Argo CD chart values (single instance, KRCI config)
values/sonarqube.yaml                    # SonarQube chart values (community, external jdbc)
manifests/argocd-appproject-krci.yaml    # Argo CD AppProject 'krci' (applied by make argocd)
manifests/argocd-appset-rbac.yaml        # cluster-scoped RBAC for the appset controller (rbac-hack)
manifests/sonar-postgres.yaml            # minimal Postgres backing SonarQube (sonar-primary)
manifests/sonar-admin-secret.yaml        # admin creds: chart setAdminPassword hook + operator auth
manifests/sonar-operator-crs.yaml        # Sonar/Group/PermissionTemplate/QualityGate/User CRs
manifests/tekton-results.yaml           # canonical KRCI Results manifest (verbatim from add-ons)
manifests/tekton-results-postgres.yaml  # minimal Postgres backing Results
manifests/tekton-results-ingress.yaml   # ingress: Results API at tekton-results.<wildcard>
manifests/gitlab.yaml                   # self-hosted GitLab CE (HTTPS, single pod)
manifests/sample-codebase.yaml          # e2e: Codebase+branch that exercises the webhook
manifests/cdpipeline-demo.yaml          # e2e: CDPipeline 'demo' + Stage 'dev' (deploy target)
manifests/krci-gitops.yaml              # KubeRocketCI GitOps repo (system/helm codebase)
scripts/e2e.sh                          # full e2e: MR -> review -> merge -> build -> deploy demo/dev
scripts/gitlab-up.sh                    # (pre-krci) deploy GitLab + bootstrap creds/secrets + CoreDNS
scripts/gitlab-integrate.sh             # (post-krci) operator CA trust + task fix + GitOps repo
scripts/gitlab-set-status.py            # corrected gitlab-set-status task script (host parse + TLS)
scripts/argocd-integrate.sh             # (post-krci) repo creds + known-hosts + ci-argocd secret + deploy task fix
scripts/sonar-integrate.sh              # (post-krci) mint token + ci-sonarqube secret in ns krci
docs/gitlab-declarative-refactor.md     # rationale for the deps-first / KRCI-last ordering
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
- **Argo CD** runs as a **single instance** (one replica each + single Redis, no
  dex/notifications/ApplicationSet), a deliberate laptop-footprint deviation from
  KRCI's documented HA install. Uses the **latest** chart (`9.5.17`); edp-cluster-add-ons
  pins `9.5.13` (both Argo CD v3.4.x). SSO off — admin password + a scoped `krci-ci`
  API token only.
- **Versions** are pinned at the top of the `Makefile` (`EDP_VERSION`,
  `PROM_CHART_VERSION`, `ARGOCD_CHART_VERSION`, the Tekton URLs, etc.). Bump there to upgrade.
- **Deferred:** Keycloak/OIDC is not deployed; a container registry for green
  builds is not configured (`global.dockerRegistry` empty).
```
