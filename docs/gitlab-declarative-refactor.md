# Refactor — deploy dependencies first, KRCI platform last (declarative GitServer)

## Goal

Reduce fragile imperative bash by letting the **edp-install / edp-tekton chart own**
the GitServer + EventListener + its Ingress (via `edp-tekton.gitServers`), instead of
`kubectl apply`-ing the GitServer and polling for the operator to create the EL.

New principle: **install everything KRCI depends on first, then install the KRCI
platform last with values that wire it to those dependencies.**

## What becomes declarative (Helm values) vs stays bash

| Concern | Before | After |
|---|---|---|
| GitServer CR | bash heredoc (`kubectl apply`) | **`edp-tekton.gitServers.gitlab` values** |
| EventListener + Ingress | operator-created after GitServer connects → **EL existence poll / race** | **chart-rendered at install — race eliminated** |
| dockerRegistry config | values | values (unchanged) |
| kaniko custom CA flag | values | values (unchanged) |
| Git creds secrets (`ci-gitlab`, `kaniko-docker-config`, `custom-ca-certificates`) | bash (post-krci) | **bash (pre-krci)** — carry GitLab-minted creds, can't be chart-owned |
| operator CA-trust mount | bash patch | bash patch (no chart hook for volumes) |
| `gitlab-set-status` task fix | bash patch | bash patch (upstream task body) |
| CoreDNS split-horizon rewrites | bash | bash |
| `krci-gitops` codebase | bash | bash (no `codebases` values section) |

Net: the GitServer/EL/Ingress imperative handling and the EL-poll are removed; the
remaining bash is secret provisioning + three small patches + DNS + one codebase.

## Phase ordering (KRCI last)

```
preflight → cluster → ingress → cert-manager → tekton
          → prometheus → tekton-results            (capability deps)
          → gitlab-up                              (GitLab + bootstrap + secrets + CoreDNS)  [bash]
          → krci  (edp-install with gitServers/registry/customCert values)  [HELM, last big install]
          → gitlab-integrate                       (operator CA patch + status-task patch + krci-gitops)  [bash]
```

- **gitlab-up** (`scripts/gitlab-up.sh`, pre-KRCI): self-signed cert; deploy GitLab;
  wait health + API/SSH ready; `allow_local_requests`; `krci` group; root PAT; SSH key;
  create ns `krci` + secrets `ci-gitlab` / `kaniko-docker-config` / `custom-ca-certificates`
  + cm `gitlab-ca`; both CoreDNS rewrites (gitlab host → svc; EL host → ingress-nginx,
  host is deterministic `el-gitlab-<ns>.<wildcard>`).
- **krci**: `helm upgrade --install edp-install` with `values/edp-install.yaml` now
  including `edp-tekton.gitServers.gitlab`. The chart creates GitServer `gitlab`,
  EventListener `edp-gitlab`, Ingress `event-listener-gitlab`. Because the
  `ci-gitlab` secret already exists, the GitServer connects on first reconcile.
- **gitlab-integrate** (`scripts/gitlab-integrate.sh`, post-KRCI): patch
  codebase-operator to trust `gitlab-ca`; patch `gitlab-set-status` task; apply
  `krci-gitops` codebase.

`make testbed` chains all phases; `make e2e` validates (green except sonar).

## Risks / spike (validated by the from-zero run)

1. **Chart EL vs operator EL ownership.** The GitServer has no `webhookUrl`, so the
   operator would also try to create `edp-gitlab`. Earlier operator logs show it logs
   *"EventListener already exists"* and defers — so the chart-owned EL should win with
   no churn. Confirm no reconcile conflict after install.
2. **GitServer connects with a pre-existing secret.** `ci-gitlab` is created before
   the chart renders the GitServer, so the operator's SSH connection check should pass
   on first reconcile. Confirm `gitserver.status.connected=true` shortly after install.

## Files touched

- `values/edp-install.yaml` — add `edp-tekton.gitServers.gitlab` (keep dockerRegistry, kaniko.customCert).
- `scripts/gitlab-up.sh` (new) + `scripts/gitlab-integrate.sh` (new); remove `scripts/gitlab.sh`.
- `Makefile` — `gitlab-up` / `gitlab-integrate` targets; reorder `testbed`; drop the
  GitServer/EL bash steps.
- `README.md` / memory — new ordering + targets.

## Rollback

Current state is committed in git; `git checkout` restores the imperative flow.
