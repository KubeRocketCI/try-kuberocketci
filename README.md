# krci-k8s — local KubeRocketCI test bed

Spin up [KubeRocketCI](https://docs.kuberocketci.io) (**3.13.5**) in a local `kind`
cluster on Docker Desktop, with Prometheus + Tekton Results, a self-hosted **GitLab**
wired for webhook-triggered pipelines, **Argo CD** for CD, and **SonarQube** for code
quality. Then run the **Portal from source** against it.

Component versions are pinned to the GitOps source of truth
([edp-cluster-add-ons](https://github.com/epam/edp-cluster-add-ons)), but installed
directly with helm/kubectl instead of Argo CD — so you can stand the platform up with a
couple of commands and poke at any component. See **[Local deviations &
patches](#local-deviations--patches)** for how this differs from a stock KRCI install.

## Prerequisites

- Docker Desktop, **≥ 8 GB RAM** (the full bed with GitLab + SonarQube wants 12 GB+).
- `kind`, `helm`, `kubectl` on PATH (`make tools` installs `kind` via brew).

## Quick start

```bash
make testbed   # ~18-20 min: all dependencies, then KRCI installed LAST
make e2e       # ~12 min: MR -> review -> merge -> build -> deploy; PASS = all green + app deployed
```

`make testbed` builds in dependency order and installs KRCI **last** so the chart wires
itself to what's already up:

```
cluster → ingress → cert-manager → Tekton → Argo CD → Prometheus → Tekton Results → SonarQube
        → gitlab-up          deploy GitLab + bootstrap creds/secrets
        → krci               edp-install; renders GitServer/EventListener/Ingress + registry
        → gitlab-integrate   operator CA trust + gitlab-set-status patch + GitOps repo
        → argocd-integrate   repo creds + known-hosts + ci-argocd secret + deploy patch
        → sonar-integrate    mint token + ci-sonarqube secret
```

Each `*-integrate` step is the **integrate** half of a *baseline → integrate* split:
the component is installed first, then wired to KRCI post-install (only what the chart
can't express itself).

```bash
make status    # cluster + KRCI + capabilities overview (also prints Portal env vars)
make token     # mint a 24h Portal login token (Portal runs from source — see below)
make down      # delete the kind cluster
```

Full from-zero validation: `make down && make testbed && make e2e`.

## What `make testbed` installs

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

KRCI core pods (ns `krci`): `cd-pipeline-operator`, `codebase-operator`, `gitfusion`,
`tekton-cache`, `tekton-interceptor`. **The in-cluster Portal is disabled — run it from
source (below).**

## Credentials (local only)

> ⚠️ **LOCAL USE ONLY.** Fixed, predictable credentials baked into a throwaway `kind`
> cluster. They are **not secret** and must **never** be used on any shared,
> internet-reachable, or production cluster. Everything serves over plain HTTP /
> self-signed TLS with no real SSO.

| Component | URL | User | Password |
|---|---|---|---|
| GitLab | https://gitlab.127.0.0.1.nip.io | `root` | `KrciLocal_2026!` |
| SonarQube | http://sonar.127.0.0.1.nip.io | `admin` | `KrciSonar_2026!` |
| Argo CD | http://argocd.127.0.0.1.nip.io | `admin` | _(chart-generated)_ |
| Grafana | http://grafana.127.0.0.1.nip.io | `admin` | `prom-operator` |

`make status` prints the live passwords for every UI. The **Portal** uses a 24h
Kubernetes bearer token (`make token`), not a password.

## Targets

`make help` lists everything. Build piecemeal or all at once — each capability target is
independent and idempotent, so you can rebuild/debug one component without touching the
rest.

```bash
make up               # prerequisites only: cluster -> ingress -> cert-manager -> tekton -> argocd
make prometheus       # add kube-prometheus-stack + Grafana
make tekton-results   # add Tekton Results + its minimal Postgres
make sonar            # add SonarQube + own Postgres + sonar-operator + CRs
make argocd           # add Argo CD (single instance) + krci AppProject
make gitlab-up        # (pre-krci)  deploy GitLab + bootstrap creds/secrets + CoreDNS
make krci             # install KubeRocketCI (renders GitServer/EL from values)
make gitlab-integrate # (post-krci) operator CA trust + gitlab-set-status patch + GitOps repo
make argocd-integrate # (post-krci) repo creds + known-hosts + ci-argocd secret + deploy patch
make sonar-integrate  # (post-krci) mint token + ci-sonarqube secret
make testbed          # the full platform, in the order shown above

make status           # cluster + KRCI + capabilities overview + Portal env vars
make token            # 24h cluster-admin bearer token (Portal login)
make e2e              # MR -> review -> merge -> build -> deploy (demo/dev)
make krci-dry-run     # render the edp-install chart without installing
make down             # delete the kind cluster
```

## Portal (run from source)

The in-cluster Portal image is disabled; run the Portal from a separate `krci-portal`
checkout at `../portal/krci-portal`:

```bash
make token                              # copy the JWT
cd ../portal/krci-portal && pnpm dev    # http://localhost:5173
```

Open http://localhost:5173 → **Sign In with Token** → paste the token. (A local dev OIDC
bypass in the portal's `loginWithToken` accepts the kube ServiceAccount token directly —
no real IdP needed.)

Point the Portal at the in-cluster services via `krci-portal/.env` (all three are printed
by `make status` under "portal env"):

```bash
TEKTON_RESULTS_URL=http://tekton-results.127.0.0.1.nip.io   # PipelineRun history
GITFUSION_URL=http://gitfusion.127.0.0.1.nip.io             # repo discovery (groups/projects/branches/PRs)
PROMETHEUS_URL=http://prometheus.127.0.0.1.nip.io           # Stage Monitoring tab
```

The chart renders ingresses for all three, so no port-forward is needed. gitfusion talks
to GitLab over HTTPS with the self-signed cert, so the chart mounts `cm gitlab-ca` into it
declaratively — otherwise discovery fails with x509 "unknown authority".

## End-to-end test (`make e2e`)

`scripts/e2e.sh` drives the whole CI→CD lifecycle, fully automated (no UI), against the
Codebase `test-go-app` (go/gin) in `manifests/sample-codebase.yaml`:

```
1. operator creates GitLab project krci/test-go-app + a project webhook
2. open an MR     -> review PipelineRun -> assert fully green (incl. sonar)
3. merge the MR   -> build  PipelineRun -> assert fully green; kaniko pushes the image
4. read the built tag from CodebaseImageStream test-go-app-main
5. create CDPipeline "demo" + Stage "dev" (manifests/cdpipeline-demo.yaml)
6. CDStageDeploy that tag -> deploy PipelineRun -> Argo CD syncs the deploy-templates
   Helm chart into ns krci-demo-dev; assert the workload is Available on the built tag
```

The **review/build trigger split** lives in the EventListener `Trigger` CRs:
`gitlab-review` fires on MR `open/reopen/update` (+ note hooks), `gitlab-build` on MR
action `merge`. So **merging** the MR — not a separate push — kicks the build. All
PipelineRuns are recorded in Tekton Results.

GitLab is a **platform dependency**: it comes up before `make krci`, and the **GitServer
/ EventListener / Ingress are rendered by the chart** from `edp-tekton.gitServers` in
`values/edp-install.yaml` — not created imperatively. See
`docs/gitlab-declarative-refactor.md` for the deps-first / KRCI-last rationale.

> **Known quirk:** GitLab can deliver the MR webhook twice, creating two concurrent runs;
> the second gets a harmless `400` posting the same commit-status context.

## Local deviations & patches

What this test bed changes relative to a stock, GitOps-managed KubeRocketCI install:

**Install method**
- **helm/kubectl, not Argo CD GitOps** — versions still pinned to edp-cluster-add-ons,
  but applied directly so each component is debuggable in isolation.
- **In-cluster Portal disabled** — run from source (above); auth via a Kubernetes bearer
  token + dev OIDC bypass instead of Keycloak/OIDC (not deployed).

**Patched Tekton tasks** (both survive `make krci` — helm's 3-way merge only resets
fields the chart itself owns):
- **`gitlab-set-status`** — the stock task mis-parsed our `ssh://…:32222/…` git URL
  (posted status to host `ssh`) and verified TLS against the self-signed cert, aborting
  every run at `report-pipeline-start-to-gitlab`. Patched (`scripts/gitlab-set-status.py`)
  to extract the host from any URL form and skip TLS verification.
- **`deploy-applicationset-cli`** — the `argocd` CLI defaults to TLS, but our server is
  plaintext; the integrate script adds `--plaintext` to `ARGOCD_OPTS`.

**Argo CD** — runs as a deliberate laptop-footprint **single instance** (one replica
each + single Redis, dex/notifications off), deviating from KRCI's documented HA install.
The ApplicationSet controller is kept (KRCI's CD deploy needs it). Uses the **latest**
chart (`9.5.17`; add-ons pins `9.5.13`). Adds an **appset RBAC hack**
(`manifests/argocd-appset-rbac.yaml`) granting the appset controller cluster-scoped
rights the chart omits, required for apps-in-any-namespace.

**SonarQube** — uses our **own minimal Postgres** (`postgresql.enabled: false` +
`jdbcOverwrite`) instead of the chart's deprecated bundled DB or Crunchy PGO. The chart
requires `monitoringPasscode` to become Ready, and its `setAdminPassword` hook automates
the forced first-login password change.

**Tekton Results** — single stock `postgres:16-alpine` (Crunchy PGO intentionally not
installed); it satisfies the canonical manifest's DB contract, used unmodified except for
pinning the `logs` PVC namespace.

**Self-hosted GitLab** — added as a platform dependency (KRCI supports
gitlab/github/gerrit/bitbucket — **not Gitea**). Serves **HTTPS with a self-signed cert**
(the operator's API client only speaks https), so the operator CA trust is mounted into
codebase-operator + gitfusion. **CoreDNS split-horizon** + a **kind containerd registry
mirror** (`hosts.toml`) let in-cluster and node-level pulls reach the GitLab registry.

**Container registry = GitLab's own** — build pipelines push to
`gitlab.127.0.0.1.nip.io:5050/krci/<codebase>` (`global.dockerRegistry` is empty in stock
KRCI). kaniko trusts the self-signed registry cert (`edp-tekton.kaniko.customCert`); a
group deploy token backs both push (`kaniko-docker-config`) and pull (`regcred`).

## Layout

```
Makefile                                # all orchestration (versions pinned at top; make help)
kind/cluster.yaml                       # single-node kind, ports 80/443 -> localhost, registry mirror
values/edp-install.yaml                 # KubeRocketCI chart values (in-cluster portal off)
values/kube-prometheus-stack.yaml       # Prometheus + Grafana values
values/argo-cd.yaml                     # Argo CD chart values (single instance)
values/sonarqube.yaml                   # SonarQube chart values (community, external jdbc)
manifests/argocd-appproject-krci.yaml   # Argo CD AppProject 'krci'
manifests/argocd-appset-rbac.yaml       # cluster-scoped RBAC for the appset controller
manifests/sonar-postgres.yaml           # minimal Postgres backing SonarQube
manifests/sonar-admin-secret.yaml       # admin creds (setAdminPassword hook + operator auth)
manifests/sonar-operator-crs.yaml       # Sonar/Group/PermissionTemplate/QualityGate/User CRs
manifests/tekton-results*.yaml          # Results manifest + minimal Postgres + ingress
manifests/gitlab.yaml                   # self-hosted GitLab CE (HTTPS, single pod, registry on :5050)
manifests/sample-codebase.yaml          # e2e: Codebase that exercises the webhook
manifests/cdpipeline-demo.yaml          # e2e: CDPipeline 'demo' + Stage 'dev'
manifests/krci-gitops.yaml              # GitOps repo (system/helm codebase KRCI requires)
scripts/e2e.sh                          # full e2e: MR -> review -> merge -> build -> deploy
scripts/gitlab-up.sh                    # (pre-krci) deploy GitLab + creds/secrets + CoreDNS
scripts/gitlab-integrate.sh             # (post-krci) CA trust + task patch + GitOps repo
scripts/gitlab-set-status.py            # corrected gitlab-set-status task script
scripts/argocd-integrate.sh             # (post-krci) repo creds + known-hosts + ci-argocd + deploy patch
scripts/sonar-integrate.sh              # (post-krci) mint token + ci-sonarqube secret
docs/gitlab-declarative-refactor.md     # rationale for deps-first / KRCI-last ordering
```

## Notes

- **DNS:** the `nip.io` wildcard (`*.127.0.0.1.nip.io`) maps every ingress host to
  localhost — no `/etc/hosts` edits.
- **Tekton webhook race:** the `tekton` target waits for the pipelines/triggers
  *webhooks* (not just controllers) before KRCI applies its Pipeline CRs, else the helm
  install fails with `connection refused` on `webhook.pipeline.tekton.dev`.
- **Versions** are pinned at the top of the `Makefile` (`EDP_VERSION`,
  `PROM_CHART_VERSION`, `ARGOCD_CHART_VERSION`, the Tekton URLs, …). Bump there to upgrade.
```
