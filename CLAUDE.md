# CLAUDE.md

Guidance for working in **try-kuberocketci** — a local [KubeRocketCI](https://docs.kuberocketci.io)
(KRCI) test bed: `kind` + the full platform (Git, Tekton/GitLab CI, Argo CD, SonarQube,
Prometheus, Portal) on Docker Desktop, macOS/Apple Silicon. `make help` lists everything;
[README.md](README.md) and [docs/](docs/) explain the design.

## Apple Silicon: NEVER install QEMU binfmt — arm64/Rosetta works by default

This is the single most important rule for this repo.

- Docker Desktop on Apple Silicon already runs **amd64** containers (GitLab CE, the
  sonar-operator, the Portal image, …) under **Rosetta**, which emulates them correctly.
- **Do NOT run `tonistiigi/binfmt --install amd64`** (or any QEMU binfmt installer). It
  **replaces Rosetta with `qemu-x86_64`** in the shared Docker-VM kernel, and QEMU's
  user-mode emulation mis-handles Go's tagged pointers → `fatal error: lfstack.push` /
  `qemu: uncaught target signal 11`. The symptoms cascade and are easy to misdiagnose:
  - GitLab's **gitaly crashes** on every `git push` / clone / `update-ref` (pre-receive
    hook declined; the codebase-operator's clone/push SIGSEGV; MRs hang in "preparing").
  - The **x86_64 GitLab Runner helper** crashes (`lfstack.push`).
  - A **fresh GitLab won't boot** (`qemu: uncaught target signal 11` during reconfigure).
  - The binfmt registration lives in the **VM kernel, so it survives `make down`** — a
    clean rebuild does NOT fix it.
- **Build container images NATIVE arm64** instead of emulating amd64. Drop any
  `--platform linux/amd64` from buildkit/kaniko, and use multi-arch base images
  (e.g. `eclipse-temurin:17-jre`, not the amd64-only `…-jre-alpine`).
- If QEMU was already installed, restore Rosetta by removing the QEMU x86_64 handler
  (Rosetta's entry survives, shadowed):
  ```bash
  docker run --privileged --rm -v /proc/sys/fs/binfmt_misc:/b alpine:3.21 \
    sh -c 'for n in qemu-x86_64 x86_64; do grep -q qemu-x86_64 /b/$n 2>/dev/null && echo -1 > /b/$n; done'
  ```
  Then wipe + reboot the affected workload (e.g. GitLab's PVCs) for a clean first boot.

See [docs/gitlab-ci.md](docs/gitlab-ci.md) for the full story.

## Commands

There is no app build/lint/unit-test step — this repo *orchestrates a cluster* via the
`Makefile`. `make help` lists every target; all are idempotent and independently runnable.

- **Stand up:** `make preflight` (RAM/tool check) → `make testbed` (~18–20 min: deps
  first, KRCI installed **last**) → `make token` (24h Portal bearer token). `make up`
  brings up only the prerequisites (cluster → ingress → cert-manager → Tekton → Argo CD).
- **Rebuild one piece:** any capability target (`make sonar`, `make argocd`,
  `make prometheus`, `make gitlab-up`, …) re-runs in isolation without touching the rest.
- **Inspect:** `make status` (cluster + tool URLs + Portal `.env` values) ·
  `make gitlab-status` (GitLab + GitServer + EventListener + runner + webhook state).
- **Tear down:** `make down` (deletes the kind cluster; nothing persists outside it).
- **Validate (these are the "tests"):** the `make e2e*` targets under [CI paths](#ci-paths).
  Each target just runs its `scripts/*.sh`, so `bash scripts/e2e.sh` (etc.) works directly
  for one path. Full from-zero: `make down && make testbed && make e2e`.

## Conventions

- **Idempotent, automated scripts.** Every `scripts/*.sh` is re-runnable. Provisioning
  (groups, tokens, deploy tokens, secrets) is done via the GitLab REST API and
  `gitlab-rails`, not manual steps. New automation should match this.
- **Deps-first / KRCI-last, baseline → integrate.** Install everything KRCI depends on
  before `make krci`; the `*-integrate` targets wire only what the chart can't express.
  See [docs/architecture.md](docs/architecture.md).
- **Documented local deviations.** Where a stock task/template can't run locally, patch
  the local copy and document why (e.g. `scripts/gitlab-set-status.py`,
  `manifests/maven-task-gitlab.yaml`, the mirrored GitLab CI component). Keep deviations
  minimal — prefer the upstream behaviour when it works.
- **Self-signed GitLab over HTTPS.** The operator's GitLab client is HTTPS-only; the CA
  (`secret/gitlab-tls`) is trusted in several places (operator mount, `gitfusion`, kaniko,
  buildkit `SSL_CERT_FILE`, runner certs). Split-horizon DNS (CoreDNS rewrites) makes
  `gitlab.127.0.0.1.nip.io` resolve to the in-cluster Service for pods.
- **GitLab pack vs API.** Normal git (`git push`/clone) works under Rosetta. The GitLab
  **commits/tags API** (gitaly OperationService) is also available and is what the e2e
  scripts use to create branches/commits without a working tree.

## CI paths

- **Tekton** (default): `make e2e` (Go) and `make e2e-java` (Java/Maven → GitLab Package
  Registry). Codebase `ciTool: tekton`; webhook → EventListener → PipelineRun.
  (`e2e-java`'s registry/Maven tasks pass; its kaniko **image** build is a known
  arm64 base-image limitation — `manifests/sample-java-codebase.yaml`,
  `custom-maven-settings.yaml`, `maven-task-gitlab.yaml`, `scripts/e2e-java.sh`.)
- **GitLab CI** (`ciTool: gitlab`, multi-CI): `make gitlab-ci && make e2e-gitlabci`
  (`gitlab-ci` = install the runner + onboard the app). The operator skips the Tekton
  EventListener and injects a
  `.gitlab-ci.yml` that uses the mirrored `kuberocketci/ci-java17-mvn` component; jobs run
  on the in-cluster GitLab Runner. See [docs/gitlab-ci.md](docs/gitlab-ci.md).

## Working here

- **Repo layout** — everything is driven by the `Makefile` (version pins + namespace
  vars are the `?=` variables at the top, lines ~8–54):
  - `scripts/*.sh` — idempotent provisioning + validation: `*-up.sh` (deploy),
    `*-integrate.sh` (post-KRCI wiring), `e2e*.sh` (the "tests"),
    `gitlab-ci-onboard.sh` / `gitlab-runner.sh`, `gitlab-set-status.py`.
  - `manifests/*.yaml` — raw k8s/CR YAML the scripts apply (sample codebases, Tekton
    tasks, secrets, configmaps).
  - `values/*.yaml` — Helm values (`edp-install`, `argo-cd`, `kube-prometheus-stack`,
    `sonarqube`, `gitlab-runner`).
  - `kind/cluster.yaml` — the kind cluster config (host ports 80/443 → localhost).
  - `docs/` — design docs (`architecture.md`, `gitlab-ci.md`, `gitlab-integration.md`).

- `kubectl` context is `kind-krci`; namespaces: `krci` (platform), `gitlab`,
  `gitlab-runner`, `sonar`, `argocd`, `monitoring`, `tekton-pipelines`.
- The shell is **zsh** — it does NOT word-split unquoted `$VAR`; for `kubectl --context …`
  in a variable, call `kubectl` directly or run the block under `bash -s`.
- GitLab first boot is slow (3–6 min) and `make e2e` ~12 min — give long-running targets
  generous timeouts rather than assuming a hang.
