#!/usr/bin/env bash
# Optional Portal access to Agent Substrate (Portal Agent mode), not part of `make testbed`. Requires
# `make substrate` and `make krci`; run after `make substrate-integrate`. Re-run after `make substrate`.
#   * namespace NS: label ate.dev/api-access=true. NetworkPolicy ate-system/ate-api-server admits
#     labelled namespaces only.
#   * global access policy: role viewer for user:system:serviceaccount:<NS>:<ServiceAccount of
#     deploy/krci-portal>, added to the existing bindings. Workers are global: an atespace role does
#     not cover them. ServiceAccount `default` is refused: the grant would cover every pod in NS.
#   * AGENT_SUBSTRATE_URL: set by the Portal values (values/edp-install.yaml,
#     values/snapshot/krci-portal.yaml), applied by `make krci`. Checked in cm/portal-config; when
#     absent, the step to apply it is printed.
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
SUBSTRATE_VERSION="${SUBSTRATE_VERSION:?SUBSTRATE_VERSION is required}"
PORTAL=krci-portal
KUBECTL="kubectl --context $CTX"
KUBECTL_ATE="kubectl ate --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PATH="$HERE/.cache/substrate/$SUBSTRATE_VERSION/bin:$PATH"
. "$HERE/scripts/lib/substrate.sh"

command -v kubectl-ate >/dev/null || { echo "FAIL kubectl-ate $SUBSTRATE_VERSION not found: run make substrate first" >&2; exit 1; }
$KUBECTL -n ate-system get service api >/dev/null 2>&1 || { echo "FAIL service ate-system/api not found: run make substrate first" >&2; exit 1; }
$KUBECTL -n "$NS" get deploy "$PORTAL" >/dev/null 2>&1 || { echo "FAIL deploy/$PORTAL not found in ns $NS: run make krci first" >&2; exit 1; }
SA="$($KUBECTL -n "$NS" get deploy "$PORTAL" -o jsonpath='{.spec.template.spec.serviceAccountName}')"
SA="${SA:-default}"
[ "$SA" != default ] || { echo "FAIL deploy/$PORTAL runs as ServiceAccount default: set a dedicated ServiceAccount" >&2; exit 1; }

echo "==> Namespace $NS: label ate.dev/api-access=true"
if [ "$($KUBECTL get namespace "$NS" -o jsonpath='{.metadata.labels.ate\.dev/api-access}')" = true ]; then
  echo "    present"
else
  $KUBECTL label namespace "$NS" ate.dev/api-access=true --overwrite >/dev/null
  echo "    added"
fi

echo "==> Global access policy: viewer for ServiceAccount $NS/$SA"
ate_policy_grant --global viewer "user:system:serviceaccount:$NS:$SA"

echo "==> AGENT_SUBSTRATE_URL in cm/portal-config"
URL="$($KUBECTL -n "$NS" get configmap portal-config -o jsonpath='{.data.AGENT_SUBSTRATE_URL}' 2>/dev/null || true)"
if [ -n "$URL" ]; then
  echo "    $URL"
else
  echo "    (todo) absent: apply the Portal values with make krci (snapshot mode: make snapshot-krci-portal)"
fi
