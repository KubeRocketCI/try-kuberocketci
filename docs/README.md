# Documentation

Design and integration docs for **try-kuberocketci** — the local
[KubeRocketCI](https://docs.kuberocketci.io) test bed. Start with the
[project README](../README.md) to run it; read these to understand *why* it's built
the way it is.

| Doc | What it covers |
|---|---|
| [architecture.md](architecture.md) | The overall design: deps-first / KRCI-last ordering, the baseline → integrate split, split-horizon DNS, the three CA-trust injection points, the registry, the task patches, and the CI → CD lifecycle. **Start here.** |
| [gitlab-integration.md](gitlab-integration.md) | The self-hosted GitLab webhook path in depth: EventListener + `gitlab` ClusterInterceptor, the review/build trigger split, HTTPS-only API client, registry reuse, and the omnibus configuration notes. |
| [registry-integration.md](registry-integration.md) | The **package** registry (maven/pypi/npm artifacts) on GitLab: publish-per-project / resolve-per-group, the settings-ConfigMap vs task-patch split, per-build `CI_PROJECT_ID`, and why the TLS trust differs per language. |
| [gitlab-ci.md](gitlab-ci.md) | Running CI in **GitLab CI instead of Tekton** (`ciTool: gitlab`): the injected `.gitlab-ci.yml`, the mirrored `ci-java17-mvn` component, the GitLab Runner, and the local deviations. Validated by `make e2e-gitlabci`. |

For the official platform documentation, see <https://docs.kuberocketci.io>.
