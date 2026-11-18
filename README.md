# try-kuberocketci — run the full KubeRocketCI platform locally in kind

> **Spin up the complete [KubeRocketCI](https://docs.kuberocketci.io) (KRCI) CI/CD
> platform on your laptop in two commands** — a self-hosted GitLab, Tekton CI,
> Argo CD for GitOps delivery, SonarQube code quality, Prometheus + Grafana, and the
> KubeRocketCI Portal — all inside a disposable `kind` cluster on Docker Desktop.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![KubeRocketCI](https://img.shields.io/badge/KubeRocketCI-3.16.1-7B42BC.svg)](https://docs.kuberocketci.io)
[![Kubernetes: kind](https://img.shields.io/badge/Kubernetes-kind-326CE5.svg)](https://kind.sigs.k8s.io/)
[![CI: Tekton](https://img.shields.io/badge/CI-Tekton-FD495C.svg)](https://tekton.dev/)
[![CD: Argo CD](https://img.shields.io/badge/CD-Argo%20CD-EF7B4D.svg)](https://argo-cd.readthedocs.io/)
[![Code Quality: SonarQube](https://img.shields.io/badge/Code%20Quality-SonarQube-4E9BCD.svg)](https://www.sonarsource.com/products/sonarqube/)
[![SCM: GitLab](https://img.shields.io/badge/SCM-GitLab-FC6D26.svg)](https://about.gitlab.com/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

**`try-kuberocketci`** is a local, reproducible **test bed / sandbox** for
KubeRocketCI — an open-source **internal developer platform (IDP)** for
cloud-native CI/CD on Kubernetes. It lets you evaluate, demo, learn, and develop
against a *complete* KRCI platform without any cloud account: everything runs in a
single-node `kind` cluster and tears down with one command. Component versions are
pinned to the GitOps source of truth
([edp-cluster-add-ons](https://github.com/epam/edp-cluster-add-ons)), but installed
directly with `helm`/`kubectl` instead of Argo CD — so you can stand the platform
up with a couple of commands and poke at any component in isolation.

**What you get, locally:**

- **Self-hosted GitLab CE** — the SCM, wired for webhook-triggered pipelines
- **Tekton Pipelines/Triggers/Results** — the CI engine and run history
- **Argo CD** — GitOps continuous delivery
- **SonarQube Community** — static analysis and quality gates
- **Prometheus + Grafana** — metrics and dashboards
- **KubeRocketCI Portal** — the platform UI, in-cluster
- **A real, automated end-to-end run** — `make e2e` drives MR → review → merge →
  build → deploy and asserts the app is live, no clicking required
- **GitLab CI as an alternative CI engine** (multi-CI) — set `ciTool: gitlab` to run
  pipelines in GitLab CI on an in-cluster runner instead of Tekton; `make e2e-gitlabci`
  proves it green. See [docs/gitlab-ci.md](docs/gitlab-ci.md)

---

## Table of contents

- [What is KubeRocketCI?](#what-is-kuberocketci)
- [Who is this for?](#who-is-this-for)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Architecture](#architecture)
- [What `make testbed` installs](#what-make-testbed-installs)
- [Credentials (local only)](#credentials-local-only)
- [Targets](#targets)
- [End-to-end test (`make e2e`)](#end-to-end-test-make-e2e)
- [Local deviations & patches](#local-deviations--patches)
- [Repository layout](#repository-layout)
- [FAQ](#faq)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

## What is KubeRocketCI?

[**KubeRocketCI**](https://docs.kuberocketci.io) (KRCI, or "Rocket") is an open-source,
Kubernetes-native **internal developer platform**
that assembles best-of-breed tools — Tekton, Argo CD, SonarQube, and your Git
provider — into a cohesive, opinionated CI/CD experience. It manages the lifecycle
of your **Codebases** (applications, libraries, autotests) from source through
review, build, and GitOps-based deployment, exposing it all through a single Portal.

This repository is **not** KubeRocketCI itself — it's a **local installer and test
harness** that brings the whole platform up on your machine so you can try it,
reproduce issues, or develop integrations against it.

## Who is this for?

- **Platform / DevOps engineers** evaluating KubeRocketCI before adopting it.
- **Contributors** to KRCI who need a fast, disposable, from-zero reproduction.
- **Developers** who want to understand the Tekton + Argo CD + SonarQube + GitLab
  CI/CD flow end-to-end without standing up cloud infrastructure.
- **Anyone learning** cloud-native CI/CD, GitOps, and platform engineering by
  reading a real, working, fully-wired example.

## Prerequisites

- **Docker Desktop**, **≥ 8 GB RAM** (the full bed with GitLab + SonarQube wants
  **12 GB+**).
- `kind` ≥ 0.32, `helm`, `kubectl` on `PATH` (`make tools` installs `kind` via brew).
- macOS (Apple Silicon or Intel) or Linux. On Apple Silicon, amd64-only Tekton task
  images run under Docker Desktop's Rosetta.

## Quick start

```bash
make testbed   # ~18-20 min: all dependencies, then KubeRocketCI installed LAST
make e2e       # ~12 min: MR -> review -> merge -> build -> deploy; PASS = all green + app deployed
```

`make testbed` builds in **dependency order** and installs KubeRocketCI **last** so
the chart wires itself to what's already up:

```
cluster → ingress → cert-manager → Tekton → Argo CD → Prometheus → Tekton Results → SonarQube
        → gitlab-up          deploy GitLab + bootstrap creds/secrets
        → krci               install KubeRocketCI (edp-install)
        → gitlab-integrate   wire GitLab to KubeRocketCI
        → argocd-integrate   wire Argo CD to KubeRocketCI
        → sonar-integrate    wire SonarQube to KubeRocketCI
```

Each `*-integrate` step wires a component to KubeRocketCI after it's installed. See
[docs/architecture.md](docs/architecture.md) for the full design.

```bash
make status    # cluster + KRCI + capabilities overview (also prints values for the Portal .env)
make token     # mint a 24h Portal login token
make down      # delete the kind cluster
```

Full from-zero validation: `make down && make testbed && make e2e`.

## Architecture

KubeRocketCI is installed **last**, after every dependency it wires to is already
running — the **deps-first / KRCI-last** principle:

```mermaid
flowchart LR
    subgraph Foundation
      A[kind] --> B[ingress-nginx] --> C[cert-manager] --> D[Tekton]
    end
    subgraph Capabilities
      D --> E[Argo CD] --> F[Prometheus] --> G[Tekton Results] --> H[SonarQube]
    end
    H --> I[GitLab CE<br/>+ creds/secrets/CoreDNS]
    I --> J([KubeRocketCI<br/>edp-install])
    J --> K[integrate:<br/>CA trust · tokens · task patches]
    K --> L{{make e2e:<br/>MR → review → merge → build → deploy}}
```

The platform install itself uses `helm`/`kubectl` (not Argo CD GitOps) so each
component is **independently rebuildable** and debuggable. The *workloads*
KubeRocketCI deploys still go through Argo CD. Read the design docs:

- **[docs/architecture.md](docs/architecture.md)** — deps-first / KRCI-last,
  baseline → integrate, split-horizon DNS, the three CA-trust injection points, the
  task patches, and the CI → CD lifecycle.
- **[docs/gitlab-integration.md](docs/gitlab-integration.md)** — the self-hosted
  GitLab webhook path in depth.
- **[docs/gitlab-ci.md](docs/gitlab-ci.md)** — running CI in **GitLab CI instead of
  Tekton** (`ciTool: gitlab`): the injected `.gitlab-ci.yml`, the mirrored
  `ci-java17-mvn` component, the GitLab Runner, and the local deviations.

## What `make testbed` installs

| Layer        | Component                                  | Version                         | Namespace        |
|--------------|--------------------------------------------|---------------------------------|------------------|
| Cluster      | kind (k8s)                                 | v1.37.0                         | —                |
| Ingress      | ingress-nginx                              | controller-v1.15.1              | ingress-nginx    |
| Certs        | cert-manager                               | v1.21.2                         | cert-manager     |
| CI engine    | Tekton Pipelines / Triggers                | v1.6.7 / v0.37.1                | tekton-pipelines |
| Platform     | KubeRocketCI (edp-install)                 | 3.16.1                          | krci             |
| Monitoring   | kube-prometheus-stack (+Grafana)           | 91.5.2                          | monitoring       |
| Run storage  | Tekton Results (+ minimal Postgres)        | v0.20.0                         | tekton-pipelines |
| CD engine    | Argo CD (single instance)                  | chart 10.9.2 / v3.5.3           | argocd           |
| Code quality | SonarQube (+ own Postgres, sonar-operator) | chart 2025.3.1 / 25.5-community | sonar            |
| SCM          | GitLab CE (+ Container Registry)           | 19.5.3-ce                       | gitlab           |

KubeRocketCI core pods (ns `krci`): `cd-pipeline-operator`, `codebase-operator`,
`gitfusion`, `tekton-cache`, `tekton-interceptor`, `krci-portal`. The Portal serves
`https://portal.127.0.0.1.nip.io`.

## Credentials (local only)

> **LOCAL USE ONLY.** Fixed, predictable credentials baked into a throwaway
> `kind` cluster. They are **not secret** and must **never** be used on any shared,
> internet-reachable, or production cluster. Everything serves over plain HTTP /
> self-signed TLS with no real SSO. See [SECURITY.md](SECURITY.md).

| Component | URL                               | User    | Password            |
|-----------|-----------------------------------|---------|---------------------|
| GitLab    | <https://gitlab.127.0.0.1.nip.io> | `root`  | `KrciLocal_2026!`   |
| SonarQube | <https://sonar.127.0.0.1.nip.io>   | `admin` | `KrciSonar_2026!`   |
| Argo CD   | <http://argocd.127.0.0.1.nip.io>  | `admin` | *(chart-generated)* |
| Grafana   | <http://grafana.127.0.0.1.nip.io> | `admin` | `prom-operator`     |

`make status` prints the live passwords for every UI. The **Portal** uses a 24h
Kubernetes bearer token (`make token`), not a password.

GitLab users (`make gitlab-users`, run by `make gitlab-up`):

| User      | Display name  | Role                 | Credentials                                                    |
|-----------|---------------|----------------------|----------------------------------------------------------------|
| `root`    | Administrator | instance admin       | password above (UI login)                                      |
| `krci-ci` | KRCI CI/CD    | Maintainer on `krci` | token + SSH key in secret `krci/ci-gitlab`; no password login  |

The optional `make substrate` installs Agent Substrate from its release images (re-run after a
Docker restart); `make substrate-integrate` then adds `krci-agent` (**KRCI Agent**, Developer on
`krci`) for Substrate agents; its token is in secret `krci-agents/gitlab`. It also installs
`krci-agent-dispatcher` (`AGENT_DISPATCHER_VERSION`, snapshot Helm repo) in `krci-agents`, with its
hook endpoint at `https://agent-dispatcher.127.0.0.1.nip.io/hook`. The chart pins the harness image
(`harnessImage`) by digest. Agent images come from the chart's agent profiles
(`deploy-templates/profiles.yaml`, ConfigMap `krci-agents/krci-agent-dispatcher-profiles`); an edit of
the ConfigMap needs no restart and applies to new sessions.

To test an unreleased dispatcher build, build it from a krci-agent-dispatcher checkout, load it into
kind with a new tag each time (kind caches by tag), then install its chart:

```bash
make -C <dispatcher> build HOST_OS=linux
docker build --build-arg TARGETARCH=arm64 -t krci-agent-dispatcher:dev-1 <dispatcher>
kind load docker-image krci-agent-dispatcher:dev-1 --name krci
make substrate-integrate AGENT_DISPATCHER_CHART=<dispatcher>/deploy-templates \
  AGENT_DISPATCHER_IMAGE=krci-agent-dispatcher:dev-1
```

After `make e2e`, `make substrate-hook` adds the dispatcher hook to `krci/test-go-app` and protects
the branch `agent/*` there (push: Developers, merge: Maintainers, force push off).

The Anthropic API key is the one external secret: create it yourself, never in a file or the repo.
Secret `krci-agents/anthropic`, key `api-key`, value = the key (`sk-ant-...`) and nothing else.
Put your key in place of `<ANTHROPIC_API_KEY>`; the same command rotates it.
`make substrate-integrate` prints it when the Secret is missing.

```bash
kubectl -n krci-agents create secret generic anthropic --from-literal=api-key=<ANTHROPIC_API_KEY> \
  --dry-run=client -o yaml | kubectl apply -f -
# check: prefix and length only
kubectl -n krci-agents get secret anthropic -o jsonpath='{.data.api-key}' | base64 -d | awk '{print substr($0,1,7) "... length " length($0)}'
```

## Targets

`make help` lists everything. Build piecemeal or all at once — each capability
target is independent and idempotent, so you can rebuild/debug one component without
touching the rest.

```bash
make up               # prerequisites only: cluster -> ingress -> cert-manager -> tekton -> argocd
make prometheus       # add kube-prometheus-stack + Grafana
make tekton-results   # add Tekton Results + its minimal Postgres
make sonar            # add SonarQube + own Postgres + sonar-operator + CRs
make argocd           # add Argo CD (single instance) + krci AppProject
make gitlab-up        # (pre-krci)  deploy GitLab + bootstrap creds/secrets
make gitlab-users     # (pre-krci)  re-onboard the GitLab users (part of gitlab-up); rotates tokens
make krci             # install KubeRocketCI (edp-install)
make gitlab-integrate # (post-krci) wire GitLab to KubeRocketCI
make argocd-integrate # (post-krci) wire Argo CD to KubeRocketCI
make sonar-integrate  # (post-krci) wire SonarQube to KubeRocketCI
make testbed          # the full platform, in the order shown above

# Optional, not part of `make testbed`
make defectdojo            # DefectDojo (chart 1.9.70 = 3.5.200) with the chart's bundled PostgreSQL + Valkey, + Trivy Operator (0.37.0)
make defectdojo-integrate  # admin API token -> ci-defectdojo, Portal DEFECTDOJO_*, krci-security-operator secret + install the operator
make defectdojo-down       # uninstall the operator, DefectDojo + Trivy Operator, delete their namespaces, the Trivy CRDs and the credentials above

make status           # cluster + KRCI + capabilities overview + values for the Portal .env
make token            # 24h cluster-admin bearer token (Portal login)
make e2e              # MR -> review -> merge -> build -> deploy (demo/dev)
make e2e-java         # Java/Maven -> GitLab Package Registry (Tekton CI)
make krci-dry-run     # render the edp-install chart without installing
make down             # delete the kind cluster

# GitLab CI instead of Tekton (multi-CI) — see docs/gitlab-ci.md
make gitlab-ci        # set up: install the GitLab Runner + mirror the ci-java17-mvn component + onboard the Java app
make e2e-gitlabci     # MR -> review pipeline -> merge -> build pipeline; PASS = both green (GitLab CI, not Tekton)
```

### Optional: DefectDojo

`make defectdojo` installs the upstream DefectDojo chart (`DEFECTDOJO_CHART_VERSION`: 1.9.70 =
DefectDojo 3.5.200, the latest stable; edp-cluster-add-ons still pins 1.9.12 = 2.55.2) in ns `defectdojo`, with the chart's bundled
PostgreSQL and Valkey and one replica of each component. It needs only `make up` (ingress-nginx);
the first start runs the DB migrations (3-6 min). UI: `http://defectdojo.127.0.0.1.nip.io`, user
`admin`, password generated by the chart (`make status` prints it). Plain http: the cookie flags
are off so the UI login works.

`make defectdojo-integrate` gets the admin API v2 token, writes it to each consumer that exists and
installs krci-security-operator. It needs no KubeRocketCI; re-run it after `make krci` for the CI
secret and the Portal:

| Consumer                | Where                                                                                      | URL                                  |
|-------------------------|--------------------------------------------------------------------------------------------|--------------------------------------|
| CI pipelines (Tekton)   | secret `krci/ci-defectdojo`, keys `url`, `token`                                           | `http://defectdojo-django.defectdojo` |
| Portal                  | `portal-config`: `DEFECTDOJO_URL`, `DEFECTDOJO_WEB_URL`, `DEFECTDOJO_CLUSTER_NAME`; `krci-portal-secret`: `DEFECTDOJO_API_KEY` | Service URL / `http://defectdojo.127.0.0.1.nip.io` |
| krci-security-operator  | secret `krci-security/defectdojo-credentials`, keys `url`, `token`                         | `http://defectdojo.127.0.0.1.nip.io` |

The operator's HTTP client verifies TLS and has no insecure option, so its URL is plain http. A
CoreDNS rewrite (added by the script) makes that host reach ingress-nginx from pods; on the host
nip.io resolves to 127.0.0.1. `defectdojo-credentials` is created only when absent, with the admin
token; a token put there by hand (for example one with minimal permissions) is kept. Delete the
Secret and re-run to get the admin token back.

krci-security-operator (`SECURITY_OPERATOR_VERSION` 0.2.0-SNAPSHOT.11, snapshot repo; stable 0.1.0
predates the namespace products and is what the edp-cluster-add-ons values target) runs in ns
`krci-security` with `clusterName` = `DEFECTDOJO_CLUSTER_NAME` (`values/krci-security-operator.yaml`).
It imports the VulnerabilityReports and ExposedSecretReports of each namespace into product
`in-cluster/<namespace>` under Product Type `KubeRocketCI`. It closes tests only for gone workloads
and for gone or excluded namespaces: a deleted report closes nothing.

To test an unreleased operator build, load it into kind with a new tag each time (kind caches by
tag), then install its chart:

```bash
GOARCH=arm64 make -C <operator> build
docker build --build-arg TARGETARCH=arm64 -t krci-security-operator:dev-1 <operator>
kind load docker-image krci-security-operator:dev-1 --name krci
make defectdojo-integrate SECURITY_OPERATOR_CHART=<operator>/deploy-templates \
  SECURITY_OPERATOR_IMAGE=krci-security-operator:dev-1
```

To run it from the host (`make run` in its repo) instead, scale the Deployment to 0 and set
`POD_NAMESPACE=krci-security DEFECTDOJO_SECRET_NAME=defectdojo-credentials CLUSTER_NAME=in-cluster`.

Install the add-ons version with `make defectdojo-down && DEFECTDOJO_CHART_VERSION=1.9.12 make defectdojo`
(2.55.2); run `make defectdojo-down` before every switch, the 2.x to 3.x database migration is one-way.

`make defectdojo` also installs the Trivy Operator (upstream chart `aquasecurity/trivy-operator`,
`TRIVY_OPERATOR_CHART_VERSION` 0.37.0) in ns `trivy-system` with the edp-cluster-add-ons values
(`values/trivy-operator.yaml`). It produces the reports that krci-security-operator imports into
DefectDojo:

- **Scope:** `targetNamespaces` = `krci,krci-demo-dev,krci-security,argocd` (no globs: add new
  Stage namespaces there). Empty = cluster-wide minus the system namespaces. Tekton TaskRun pods
  (label `tekton.dev/taskRun`) are skipped. Local deviation: the add-ons scan cluster-wide.
- **Mode:** a built-in Trivy server holds the vulnerability DB (5Gi PVC). Scan jobs run in
  `trivy-system`, at most 3 at a time.
- **Scan:** `rootfs` scan of the image already on the node, as uid 65534, reporting HIGH and CRITICAL
  findings that have a fix. No SBOM reports. Reports are kept 168h.
- **Reports:** VulnerabilityReport and ExposedSecretReport only, the kinds krci-security-operator
  imports. Local deviation: config audit, RBAC assessment, infra assessment and compliance scanners
  are off.
- **Status:** `make status` counts the VulnerabilityReports.
- **Known failure:** scans of images whose working directory is unreadable to uid 65534 fail with
  `open trivy.yaml: permission denied` and produce no report. Trivy reads `trivy.yaml` from the
  working directory and ignores only "not found". This hits distroless `nonroot` images:
  `/home/nonroot` is `0700 65532:65532` (cert-manager, node-exporter `-distroless`, Agent
  Substrate). The chart has no setting for the scan container's working directory or the trivy
  config path.
- **Pull-secret images:** since Kubernetes 1.35 the kubelet lets a pod use a cached image pulled
  with imagePullSecrets only when the pod carries matching credentials. The rootfs scan pods in
  `trivy-system` get no pull secret from trivy-operator, so GitLab-registry images (Stage pull
  secret `regcred`, so every Stage app) fail with `ErrImageNeverPull`, as on any cluster with the
  edp-cluster-add-ons values. `make defectdojo-integrate` copies `krci/regcred` to
  `trivy-system/krci-regcred` and adds it to the imagePullSecrets of ServiceAccount
  `trivy-operator`; Kubernetes adds them to every scan pod. The kubelet keeps its default check
  (`imagePullCredentialsVerificationPolicy: NeverVerifyPreloadedImages`). For images of another
  private registry, add its pull secret to the same ServiceAccount. A scan that already failed is
  retried only when the workload changes or trivy-operator restarts.

2.55.2 and 3.5.200 differ as follows; `make defectdojo-integrate` is the same for both (the admin
user is a superuser, the token route `/api/v2/api-token-auth/` and the API v2 paths are unchanged):

| | 2.55.2 | 3.5.200 |
|---|---|---|
| UI names | Products, Product Types | Assets, Organizations (API v2 paths still `/products/`, `/product_types/`) |
| Access for a non-admin token | Product Type roles (Maintainer for product edit and import); roles and member APIs exist | staff, or authorized user of the Product Type; the creator of an auto-created type is not made a member |

### Snapshot mode (`SNAPSHOT=true`)

`SNAPSHOT=true make testbed` installs the KRCI charts from the **snapshot** helm repo
(`https://epam.github.io/edp-helm-charts/snapshot`, semver pre-releases via `--devel`)
instead of the pinned release. The umbrella `edp-install` then renders only the shared
base (all subcharts disabled) and each component becomes its **own helm release** —
CRD-owning operators first, then `edp-tekton`, `gitfusion`, `krci-portal` — mirroring
the per-chart layout of the KRCI dev GitOps environments. Snapshot scope is
`edp-install` and its subcomponents ONLY: SonarQube and `sonar-operator` always
install from their stable pins regardless of the switch. Release names equal chart
names, so every resource keeps the name the umbrella would give it and
`status`/`*-integrate`/`e2e` work unchanged.

- Per-chart values live in `values/snapshot/` (the umbrella sections of
  `values/edp-install.yaml` flattened; `global.yaml` is passed to every release
  because standalone charts don't inherit umbrella globals).
- Pick a mode **per cluster** (from scratch only) — `make down` first to switch.
- Re-roll one chart: `make snapshot-edp-tekton`; pin a version:
  `SNAP_VERSION_edp-tekton=0.27.0-SNAPSHOT.30`; list versions: `make snapshot-versions`.

## End-to-end test (`make e2e`)

`scripts/e2e.sh` drives the whole CI→CD lifecycle, fully automated (no UI), against
the Codebase `test-go-app` (go/gin) in `manifests/sample-codebase.yaml`:

```txt
1. operator creates GitLab project krci/test-go-app + a project webhook
2. open an MR     -> review PipelineRun -> assert fully green (incl. sonar)
3. merge the MR   -> build  PipelineRun -> assert fully green; kaniko pushes the image
4. read the built tag from CodebaseImageStream test-go-app-main
5. create CDPipeline "demo" + Stage "dev" (manifests/cdpipeline-demo.yaml)
6. CDStageDeploy that tag -> deploy PipelineRun -> Argo CD syncs the deploy-templates
   Helm chart into ns krci-demo-dev; assert the workload is Available on the built tag
```

Opening or updating the MR triggers the review pipeline; **merging** it — not a
separate push — kicks the build. All PipelineRuns are recorded in Tekton Results.

GitLab is a **platform dependency**: it comes up before `make krci`. See
[docs/architecture.md](docs/architecture.md) for the deps-first / KRCI-last design.

> **Known quirk:** GitLab can deliver the MR webhook twice, creating two concurrent
> runs; the second gets a harmless `400` posting the same commit-status context.

## Local deviations & patches

This test bed differs from a stock, GitOps-managed KubeRocketCI install in a few
deliberate ways. Each is documented in full — with the rationale — in
**[docs/architecture.md](docs/architecture.md)**; this is the summary:

| Area           | Deviation                                                                                                                                 |
|----------------|-------------------------------------------------------------------------------------------------------------------------------------------|
| Install method | `helm`/`kubectl`, not Argo CD GitOps, so each component is debuggable in isolation (versions still pinned to edp-cluster-add-ons)         |
| Portal         | in-cluster subchart; image pinned to snapshot `0.11.0-SNAPSHOT.2` (arm64); OIDC disabled — ServiceAccount-token login only (`make token`) |
| Tekton tasks   | `gitlab-set-status` and `deploy-applicationset-cli` patched for self-signed GitLab / plaintext Argo CD, re-applied after each `make krci` |
| Argo CD        | single instance (not HA), chart `10.9.2`, plus an apps-in-any-namespace RBAC addition the chart omits                                     |
| SonarQube      | own minimal Postgres instead of the bundled DB / Crunchy PGO                                                                              |
| DefectDojo     | optional; the chart's bundled PostgreSQL + Valkey instead of Crunchy PGO; no SSO / ESO; plain http, cookie flags off                      |
| Tekton Results | single stock `postgres:16-alpine` (no Crunchy PGO)                                                                                        |
| GitLab         | self-hosted dependency on self-signed HTTPS; CoreDNS split-horizon + containerd registry mirror                                           |
| Registry       | reuses GitLab's own Container Registry at `:5050` instead of a separate one                                                               |
| Chart source   | optional `SNAPSHOT=true` mode installs pre-release charts, one release per chart (see [Snapshot mode](#snapshot-mode-snapshottrue))       |
| Image cache    | `make preload` (auto in `gitlab-up`) keeps the ~3GB GitLab image in the host docker cache so rebuilds skip the download                   |

For the how and why behind each row, see [docs/architecture.md](docs/architecture.md)
and [docs/gitlab-integration.md](docs/gitlab-integration.md).

## Repository layout

```
Makefile                                # all orchestration (versions pinned at top; make help)
kind/cluster.yaml                       # single-node kind, ports 80/443 -> localhost, registry mirror
values/edp-install.yaml                 # KubeRocketCI chart values (in-cluster portal on)
values/snapshot/                        # SNAPSHOT mode: per-chart values (umbrella base + one file per release)
values/kube-prometheus-stack.yaml       # Prometheus + Grafana values
values/argo-cd.yaml                     # Argo CD chart values (single instance)
values/sonarqube.yaml                   # SonarQube chart values (community, external jdbc)
values/defectdojo.yaml                  # (optional) DefectDojo chart values (bundled PostgreSQL + Valkey, plain http)
values/trivy-operator.yaml              # (optional, make defectdojo) Trivy Operator chart values = edp-cluster-add-ons
values/krci-security-operator.yaml      # (optional, make defectdojo-integrate) krci-security-operator chart values
values/gitlab-runner.yaml               # GitLab CI: GitLab Runner chart values (k8s executor, native arm64)
manifests/krci-portal-secret.yaml       # Portal SERVER_SECRET (applied pre-krci; OIDC disabled, token login only)
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
manifests/sample-gitlabci-codebase.yaml # GitLab CI: ciTool=gitlab Codebase + branch
manifests/gitlab-ci-java-maven-configmap.yaml # GitLab CI: injected .gitlab-ci.yml template (mirrored component)
scripts/e2e.sh                          # full e2e: MR -> review -> merge -> build -> deploy
scripts/gitlab-up.sh                    # (pre-krci) deploy GitLab + creds/secrets + CoreDNS
scripts/gitlab-users.sh                 # GitLab users: Administrator profile, krci-ci -> ci-gitlab
scripts/lib/gitlab.sh                   # GitLab helpers: gl_rails, onboard_gitlab_user, apply_secret
scripts/gitlab-rails/*.rb               # gitlab-rails runner scripts (users, group, deploy tokens, runner)
scripts/gitlab-integrate.sh             # (post-krci) SSH known-hosts pin + CA trust + task patch + GitOps repo
scripts/gitlab-set-status.py            # corrected gitlab-set-status task script
scripts/argocd-integrate.sh             # (post-krci) repo creds + known-hosts + ci-argocd + deploy patch
scripts/sonar-integrate.sh              # (post-krci) mint token + ci-sonarqube secret
scripts/defectdojo-integrate.sh         # (optional) admin API token -> ci-defectdojo, Portal DEFECTDOJO_*, krci-security-operator secret + release; --remove for defectdojo-down
scripts/substrate.sh                    # (optional) Agent Substrate: release images + kubectl-ate (.cache/substrate/)
scripts/substrate-integrate.sh          # (post-krci, optional) landing zone krci-agents: egress gateway CA, namespace/atespace/WorkerPool/namespace policy, GitLab user krci-agent, krci-agent-dispatcher
scripts/substrate-hook.sh               # (post-e2e, optional) krci-agent-dispatcher project hook + protected branch agent/* on test-go-app, test delivery
scripts/gitlab-runner.sh                # GitLab CI: install + register the GitLab Runner
scripts/gitlab-ci-onboard.sh            # GitLab CI: mirror the ci-java17-mvn component + onboard the app
scripts/e2e-gitlabci.sh                 # GitLab CI: e2e (MR -> review -> merge -> build; not Tekton)
docs/architecture.md                    # design: deps-first/KRCI-last, DNS, CA trust, CI→CD lifecycle
docs/gitlab-integration.md              # self-hosted GitLab webhook path in depth
docs/gitlab-ci.md                       # GitLab CI instead of Tekton (ciTool: gitlab) + the GitLab Runner
```

## FAQ

**What is this repository, exactly?**
A one-command **local installer and test harness** that brings the full
KubeRocketCI platform up in a `kind` cluster on Docker Desktop. It is not KRCI
itself — it installs and wires KRCI plus its dependencies for local use.

**How long does it take and what does it need?**
About **18–20 minutes** for `make testbed` and **~12 minutes** for `make e2e`, on
Docker Desktop with **12 GB+ RAM** allocated for the full bed.

**Does it work on Apple Silicon (arm64)?**
Yes. Platform images are multi-arch. amd64-only Tekton task images (`epamedp/tekton-*`,
`sonar-scanner-cli`, …) run under Docker Desktop's Rosetta emulation.

**Can I install just one component?**
Yes — every capability target (`make sonar`, `make argocd`, `make prometheus`, …)
is independent and idempotent. Rebuild or debug one without touching the rest.

**Is it safe to expose this or use it in production?**
**No.** It uses fixed credentials, self-signed certs, skipped TLS verification, and
broad RBAC, all bound to localhost. It is a throwaway local bed only — see
[SECURITY.md](SECURITY.md).

**How is this different from a real KubeRocketCI install?**
The platform is installed with `helm`/`kubectl` instead of Argo CD GitOps (so each
piece is debuggable), Argo CD runs single-instance instead of HA, and a handful of
local patches/credentials make self-signed GitLab and plaintext Argo CD work. See
[Local deviations & patches](#local-deviations--patches).

**How do I upgrade a component version?**
Versions are pinned at the top of the `Makefile` (`EDP_VERSION`,
`PROM_CHART_VERSION`, `ARGOCD_CHART_VERSION`, the Tekton URLs, …) and in
`values/*.yaml`. Bump there; each can be overridden ad hoc with `make VAR=value`.

**How do I tear everything down?**
`make down` deletes the whole `kind` cluster. Nothing persists outside it.

## Documentation

- **This repo:** [docs/architecture.md](docs/architecture.md) ·
  [docs/gitlab-integration.md](docs/gitlab-integration.md) ·
  [docs/gitlab-ci.md](docs/gitlab-ci.md)
- **Official KubeRocketCI docs:** <https://docs.kuberocketci.io>

## Contributing

Contributions are welcome — bug reports, version bumps, new local-platform
capabilities, and docs. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and our
[Code of Conduct](CODE_OF_CONDUCT.md). For security issues, follow
[SECURITY.md](SECURITY.md) (do not open public issues for vulnerabilities).

## Notes

- **DNS:** the `nip.io` wildcard (`*.127.0.0.1.nip.io`) maps every ingress host to
  localhost — no `/etc/hosts` edits.
- **Versions** are pinned at the top of the `Makefile` (`EDP_VERSION`,
  `PROM_CHART_VERSION`, `ARGOCD_CHART_VERSION`, the Tekton URLs, …). Bump there to
  upgrade.

## License

Licensed under the [Apache License 2.0](LICENSE). Copyright 2026 The KubeRocketCI
Authors. See [NOTICE](NOTICE) for third-party attributions — the upstream
components this repo installs remain under their own licenses.
