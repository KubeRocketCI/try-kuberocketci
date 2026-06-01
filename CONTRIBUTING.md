# Contributing to try-kuberocketci

Thanks for your interest in improving **try-kuberocketci** — the local
[KubeRocketCI](https://docs.kuberocketci.io) test bed! Contributions of all
kinds are welcome: bug reports, fixes, version bumps, documentation, and new
local-platform capabilities.

By participating you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to contribute

- **Report a bug** — open a [bug report](https://github.com/KuberocketCI/try-kuberocketci/issues/new/choose)
  with your OS, Docker/`kind` versions, and the failing `make` target.
- **Suggest an improvement** — open a feature request describing the use case.
- **Bump a pinned version** — versions live at the top of the `Makefile` and in
  `values/*.yaml`; keep them aligned with the GitOps source of truth,
  [edp-cluster-add-ons](https://github.com/epam/edp-cluster-add-ons).
- **Improve docs** — the README and `docs/` are first-class; clarity fixes are
  very welcome.

## Project layout

This repo is **orchestration**, not application code. Everything is driven by a
single `Makefile` plus shell scripts, Helm values, and Kubernetes manifests:

| Path           | What lives here                                              |
|----------------|-------------------------------------------------------------|
| `Makefile`     | All targets and pinned versions (`make help`)               |
| `scripts/`     | Bash/Python automation for install + integration + e2e      |
| `values/`      | Helm chart values for each component                        |
| `manifests/`   | Kubernetes resources applied directly                       |
| `kind/`        | `kind` cluster definition                                   |
| `docs/`        | Architecture and integration design notes                   |

See the [Architecture](docs/architecture.md) doc for the **deps-first /
KRCI-last** and **baseline → integrate** design before changing install order.

## Development workflow

1. **Fork** the repo and create a topic branch off `main`.
2. **Make your change.** Prefer keeping behavior **idempotent** — every target
   should be safe to re-run, and pinned versions should be overridable via
   `make VAR=value`.
3. **Validate locally.** The ground truth is a clean from-zero run:

   ```bash
   make down && make testbed && make e2e
   ```

   `make e2e` must end green (MR → review → merge → build → deploy). If your
   change touches a single component, you can iterate with that component's
   target (e.g. `make sonar`) since each is independent and idempotent.
4. **Lint your shell.** Please run [`shellcheck`](https://www.shellcheck.net/) on
   any script you touch and keep YAML valid.
5. **Update docs.** If you change targets, ordering, versions, or credentials,
   update the `README.md` (and `docs/` if the design changes).

## Pull requests

- Keep PRs focused; one logical change per PR.
- Use clear, imperative commit messages (Conventional Commits style is
  appreciated, e.g. `feat:`, `fix:`, `docs:`, `chore:`).
- Fill in the PR template, including which `make` targets you ran to validate.
- By submitting a contribution you agree it is licensed under the
  [Apache License 2.0](LICENSE), consistent with the rest of this project.

## Reporting security issues

Please do **not** file public issues for vulnerabilities. Follow the
[Security Policy](SECURITY.md) instead.

## Questions

Open an [issue](https://github.com/KuberocketCI/try-kuberocketci/issues),
or learn more about the platform at <https://docs.kuberocketci.io>.
