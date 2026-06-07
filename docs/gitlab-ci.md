# GitLab CI as the CI engine (instead of Tekton)

KubeRocketCI (KRCI) 3.13 added **multi-CI** support: a `Codebase` can set
`spec.ciTool: gitlab` and run its pipelines in **GitLab CI** — on a GitLab Runner —
instead of Tekton. This page documents how `try-kuberocketci` stands that path up
locally and validates it end-to-end (`make e2e-gitlabci`), alongside the existing
Tekton path. For the Tekton/webhook integration see
[gitlab-integration.md](gitlab-integration.md); for the platform install see
[architecture.md](architecture.md).

## What changes when `ciTool: gitlab`

The codebase-operator (2.33.0) reconcile chain branches on `spec.ciTool`:

| Step | `ciTool: tekton` (default) | `ciTool: gitlab` |
|---|---|---|
| Webhook / EventListener | creates the Tekton `EventListener` + project webhook | **skipped** (`put_webhook.go` returns early for non-Tekton) |
| `.gitlab-ci.yml` | — | the operator **injects** it: clones the repo, renders a template, commits and pushes |
| CI execution | Tekton `PipelineRun`s | GitLab CI jobs on a **GitLab Runner** |

The operator does the injection itself here (no manual step) — `make gitlab-ci`
prints `.gitlab-ci.yml: injected by codebase-operator ✓`. The same `gitlab` GitServer is
reused for both engines — GitLab-CI and Tekton codebases live side by side, so no
`GitServer.tektonDisabled` is needed.

### The `.gitlab-ci.yml` template ConfigMap

The operator resolves the template from a ConfigMap, by precedence:
`gitlab-ci-{lang}-{buildtool}` → `gitlab-ci-{lang}` → `gitlab-ci-default`, or an
explicit name via the `app.edp.epam.com/gitlab-ci-template` Codebase annotation. Only
`{{.CodebaseName}}` is substituted. We ship
[`manifests/gitlab-ci-java-maven-configmap.yaml`](../manifests/gitlab-ci-java-maven-configmap.yaml)
(`gitlab-ci-java-maven`), selected by the annotation on
[the sample Codebase](../manifests/sample-gitlabci-codebase.yaml).

## The pipeline: real KubeRocketCI GitLab CI components

The template uses the upstream KubeRocketCI **GitLab CI/CD component**
[`kuberocketci/ci-java17-mvn`](https://gitlab.com/kuberocketci/ci-java17-mvn) — a
Java-17/Maven library exposing `review` and `build` entry points over a mandatory
7-stage flow (`prepare → test → build → verify → package → publish → release`):

- **review** (merge request): `init-values, test, build, lint (checkstyle),
  compile-check, helm-docs, helm-lint, sonar, dockerfile-lint (hadolint),
  dockerbuild-verify` (buildkit, no push).
- **build** (protected/default branch): the above plus `buildkit-build` (build **and
  push** the image), `maven-deploy`, and `git-tag`.

GitLab CI/CD components only resolve **on the same GitLab instance** (`$CI_SERVER_FQDN`),
so `scripts/gitlab-ci-onboard.sh` **mirrors** the component into the local GitLab as
`kuberocketci/ci-java17-mvn` (tag `0.1.1`). The application is seeded from the component
repo's own sample sources (a Spring-Boot app + Helm chart), built to pass exactly these
jobs — green by construction. SonarQube CE here carries the **community branch plugin**,
so the component's branch/MR `sonar` analysis works unchanged.

## The GitLab Runner

KRCI does **not** bundle a runner. `make gitlab-ci`'s first half
([`scripts/gitlab-runner.sh`](../scripts/gitlab-runner.sh)) installs the official
`gitlab/gitlab-runner` chart (Kubernetes executor, appVersion 17.5.x to match GitLab CE
17.5), registered with a GitLab 17.x **runner authentication token** minted via
`POST /api/v4/user/runners`. Notable local settings
([`values/gitlab-runner.yaml`](../values/gitlab-runner.yaml)):

- **Native arm64 helper pinned** — the executor otherwise auto-selects the **x86_64**
  helper image; pinning the arm64 helper keeps the helper native (no emulation). Build
  images (maven, alpine, buildkit, eclipse-temurin) are multi-arch and run native too.
- **CA trust + `GIT_SSL_NO_VERIFY`** so the runner and job pods reach the self-signed
  GitLab over HTTPS.

> ### Do NOT install QEMU binfmt
> On Apple Silicon, Docker Desktop runs amd64 containers (incl. GitLab CE) under
> **Rosetta**, which emulates them correctly. Running `tonistiigi/binfmt --install amd64`
> **replaces Rosetta with `qemu-x86_64`** in the shared Docker-VM kernel — and QEMU
> user-mode mis-emulates Go's tagged pointers (`fatal error: lfstack.push`). Under QEMU,
> GitLab's gitaly crashes on every git push/clone/`update-ref`, MRs hang in "preparing",
> the x86_64 runner helper crashes, and a fresh GitLab won't even boot (`qemu: uncaught
> target signal 11` during reconfigure). The binfmt registration lives in the VM kernel,
> so it survives `make down`. **The runner script deliberately does not install it.** If
> something already did, remove the QEMU handler so Rosetta takes over again:
> ```bash
> docker run --privileged --rm -v /proc/sys/fs/binfmt_misc:/b alpine:3.21 \
>   sh -c 'for n in qemu-x86_64 x86_64; do grep -q qemu-x86_64 /b/$n 2>/dev/null && echo -1 > /b/$n; done'
> ```

## Local deviations (and why)

Because we don't emulate amd64, the only deviations are the two the local environment
genuinely needs — applied to the **mirrored** component (not upstream) by
`scripts/gitlab-ci-onboard.sh`, in the same documented-deviation spirit as the Tekton
`gitlab-set-status`/`maven` patches:

| Concern | Upstream | Here | Why |
|---|---|---|---|
| Image platform | `--platform linux/amd64` | **native arm64** (flag removed) | no QEMU; build for the node's arch |
| App `Dockerfile` base | `eclipse-temurin:17-jre-alpine` (amd64-only) | multi-arch `eclipse-temurin:17-jre` | so the arm64 build has a base image |
| Image registry | Docker Hub (`DOCKERHUB_*`) | in-cluster **GitLab registry** via the job token (`$CI_REGISTRY*`) | local-only, no Docker Hub creds |
| buildkit registry TLS | system CAs | `SSL_CERT_FILE` bundle = system CAs **+ GitLab CA** (group file var `GITLAB_REGISTRY_CA`) | registry **and its jwt/auth token host** are self-signed |

Everything else — including `git-tag` (`git push`) and the operator's clone/inject/push —
runs upstream-as-is, because gitaly is healthy under Rosetta. The Codebase also sets
`disablePutDeployTemplates: true` so the operator doesn't overwrite the sample's
`deploy-templates/` chart (which the `helm-lint`/`helm-docs` jobs use).

## Run it

```bash
make testbed       # full platform (or ensure it's already up)
make gitlab-ci     # set up: install the runner + mirror the component + seed the app + CI vars + Codebase
make e2e-gitlabci  # MR -> review pipeline -> merge -> build pipeline; PASS = both green
```

`make gitlab-status` shows the runner and the GitLab-CI codebase. The app, its pipelines,
and the pushed image are at `https://gitlab.127.0.0.1.nip.io/krci/java-gitlabci-app`.
`make e2e-gitlabci` also asserts **zero Tekton PipelineRuns** for the codebase — proving
CI ran in GitLab CI, not Tekton.

## Related files

| File | Role |
|---|---|
| `values/gitlab-runner.yaml`, `scripts/gitlab-runner.sh` | runner install + registration (k8s executor, arm64 helper) |
| `scripts/gitlab-ci-onboard.sh` | mirror the component (patched), seed the app, CI vars, Codebase |
| `manifests/gitlab-ci-java-maven-configmap.yaml` | the injected `.gitlab-ci.yml` template (mirrored component @0.1.1) |
| `manifests/sample-gitlabci-codebase.yaml` | the `ciTool: gitlab` Codebase + branch |
| `scripts/e2e-gitlabci.sh` | the end-to-end validation (GitLab pipelines API) |
