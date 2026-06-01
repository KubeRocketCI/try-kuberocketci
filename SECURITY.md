# Security Policy

## This is a local-only test bed — not a hardened deployment

`try-kuberocketci` exists to stand up a **disposable local KubeRocketCI platform**
in a `kind` cluster on your laptop. It deliberately trades security for
convenience and **must never be exposed to the internet or used in production**:

- **Fixed, well-known credentials** are baked into the manifests (see the README
  "Credentials" table). They are *not* secrets.
- **Self-signed TLS** is used everywhere, and several integrations **skip TLS
  verification** on purpose (self-signed GitLab, plaintext Argo CD).
- **Broad RBAC** is granted for convenience (e.g. an apps-in-any-namespace
  ApplicationSet RBAC hack, a cluster-admin Portal login token).
- Everything binds to `127.0.0.1` / `*.127.0.0.1.nip.io`, i.e. localhost only.

Do **not** reuse any credential, certificate, token, or value from this repo on
any shared, internet-reachable, or production cluster.

## Reporting a vulnerability

This repository is configuration and automation glue; most security-relevant
code lives in the upstream components it installs.

- **A vulnerability in this repo** (e.g. a script that leaks a credential beyond
  the local cluster, or an insecure default that could affect users following
  the README): please report it privately via
  [GitHub Security Advisories](https://github.com/KuberocketCI/try-kuberocketci/security/advisories/new)
  or by email to **SupportEPMD-EDP@epam.com**. Please do not open a public issue
  for undisclosed vulnerabilities.
- **A vulnerability in KubeRocketCI itself**: report it through the
  [KubeRocketCI project](https://docs.kuberocketci.io) channels.
- **A vulnerability in a third-party component** (Tekton, Argo CD, SonarQube,
  GitLab, Prometheus, etc.): report it to that project upstream.

We aim to acknowledge reports within 5 business days.

## Supported versions

This is a rolling test bed pinned to specific upstream versions (see the
`Makefile`). Only the latest `main` is maintained; there are no backports.
