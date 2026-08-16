# Package registry integration (GitLab Package Registry)

Language packages (maven / pypi / npm) live in the GitLab that already hosts the code —
there is no Nexus in this testbed. Container images are a separate mechanism; see
[architecture.md](architecture.md#container-registry-reuse-gitlabs-own).

## One rule for every language

> **PUBLISH** to the codebase's own GitLab **project** registry.
> **RESOLVE** from the `krci` **group** registry.

The group endpoint is a virtual aggregate over every project in the group, so a consumer
names a coordinate and never a project. Publishing is per-project because GitLab has no
group-level upload for any format.

```
                      publish (per project)            resolve (per group)
  test-java-app  ──► /api/v4/projects/krci%2Ftest-java-app/packages/maven
  foo (java lib) ──► /api/v4/projects/krci%2Ffoo/packages/maven
                                    │
                                    └──────────►  /api/v4/groups/krci/-/packages/maven
                                                  (aggregates all of the above)
```

Public dependencies arrive through that same group URL for pypi and npm — GitLab forwards
index misses to pypi.org / registry.npmjs.org. Maven forwarding is license-gated, so
`manifests/gitlab-maven-settings.yaml` carries no `<mirrors>` and Maven reaches Central
directly, with GitLab added only as an extra repository.

## Two layers per language

| Layer | Carries | Lifecycle |
|---|---|---|
| **settings ConfigMap** — `manifests/gitlab-{maven,npm,python}-settings.yaml` | Whatever the ecosystem's own config language can express: URLs, credentials | Ours. `values/edp-install.yaml` points `edp-tekton.tekton.configs.{maven,npm,python}ConfigMap` at these names, so Helm neither renders nor owns them — a plain `kubectl apply`. |
| **task patch** — `manifests/{maven,python,npm,edp-npm,edp-pnpm}-task-gitlab.yaml` | Only what that config language *cannot* express: the per-build project id and TLS trust | Chart-owned. Helm SSA resets these on every `make krci`, so they are re-applied with `--force-conflicts`. |

`make gitlab-integrate` applies both.

## The per-build project id

A publish URL needs `projects/<id>`, which no `settings.xml` / `.npmrc` / env-var file can
know. Each publishing task gains a **`derive-project`** pre-step: it reads the cloned
repo's `.git/config`, takes `group/name` from the origin remote, url-encodes it to
`group%2Fname` (GitLab accepts an encoded path as `:id`) and writes it to a shared
`emptyDir` as `CI_PROJECT_ID`. How that value reaches the config differs:

| Language | Mechanism |
|---|---|
| **maven** | `settings.xml` reads `${env.CI_PROJECT_ID}`. |
| **npm / pnpm** | Both expand `${VAR}` from the environment when reading `.npmrc`, so the ConfigMap holds `${CI_PROJECT_ID}` literally. |
| **python** | The ConfigMap holds path fragments consumed as env vars, and the shell does not re-expand a variable's contents — the task expands them with `sed` (not `eval`, which would execute ConfigMap content). |

## TLS trust

GitLab serves a self-signed cert; the CA lives in `cm/gitlab-ca`. The two ecosystems take
it differently:

- **`PIP_CERT` / `TWINE_CERT` replace the trust store**, so the python task concatenates
  the GitLab CA onto the system bundle — with the bare CA, the group index's redirect to
  pypi.org fails to verify.
- **`NODE_EXTRA_CA_CERTS` is additive** to Node's bundled roots, so npm and pnpm point
  straight at the bare CA file.

Build tasks need the CA too, not just publish tasks: `npm ci` and `pnpm i` both pull from
the group registry.

## Which task does what

| Task | Role | Gets from the patch |
|---|---|---|
| `maven` | build + `mvn deploy` | JVM truststore, `CI_PROJECT_ID`, wagon transport (GitLab rejects the default transport on upload) |
| `python` | build + `twine upload` | `CI_PROJECT_ID` expansion, merged CA bundle |
| `npm` | `npm publish` (also the build step of antora and pnpm pipelines) | `CI_PROJECT_ID`, `NODE_EXTRA_CA_CERTS`, `NPM_CACHE_DIR` |
| `edp-npm` | `npm ci` | `NODE_EXTRA_CA_CERTS` |
| `edp-pnpm` | `pnpm i` | `npm_config_userconfig`, `NODE_EXTRA_CA_CERTS` |

When editing the `.npmrc` files, note that npm matches `_authToken` against the **exact**
registry path — a shorter prefix such as `//host/api/v4/` gives `ENEEDAUTH` even with a
correct registry URL.

## Credentials

One GitLab group deploy token (`krci-packages`, read+write on the package registry) backs
every language, delivered by `scripts/gitlab-up.sh` as secret `ci-nexus`
(`username` / `password` / `url`). Maven uses it as HTTP Basic, npm/pnpm as `_authToken`,
python via `~/.netrc` plus twine env vars.

## Verifying

`make e2e-java` is the automated gate: it onboards a maven codebase, opens and merges an
MR, asserts the pipeline tasks are green and lists the published packages.

For python, npm and pnpm, onboard a library codebase of that type (Portal → Components →
Create, or a `Codebase` CR), merge an MR, then check both ends of the rule:

```bash
PAT=$(kubectl -n krci get secret ci-gitlab -o jsonpath='{.data.token}' | base64 -d)
POD=$(kubectl -n gitlab get pod -l app=gitlab -o jsonpath='{.items[0].metadata.name}')
gl(){ kubectl -n gitlab exec "$POD" -- curl -sk -H "PRIVATE-TOKEN: $PAT" "https://localhost/api/v4/$1"; }

gl "projects/krci%2F<codebase>/packages"   # published to its OWN project
gl "groups/krci/packages"                  # aggregated for every consumer
```
