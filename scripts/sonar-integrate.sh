#!/usr/bin/env bash
# Phase: post-KRCI SonarQube integration. Runs AFTER `make sonar` (SonarQube + operator
# + CRs up) and `make krci` (the `krci` namespace exists). Pairs with `make sonar`.
# The only KRCI-coupled bit: mint a token for the operator-created `ci-user` and store
# it as the `ci-sonarqube` integration secret that the edp-tekton `sonar` task reads.
# Docs: https://docs.kuberocketci.io/docs/operator-guide/code-quality/sonarqube
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
SONAR_NS="${SONAR_NS:-sonar}"
WILDCARD="${WILDCARD:-127.0.0.1.nip.io}"
SONAR_HOST="sonar.${WILDCARD}"
# https directly (self-signed -> -k): the ingress force-redirects http -> https,
# and curl strips the Authorization header on the port change of a followed
# redirect, which turns every authenticated API call into an anonymous one.
SONAR_API="https://${SONAR_HOST}"
SONAR_SVC_URL="http://sonar.${SONAR_NS}.svc:9000"   # in-cluster URL the sonar task uses
KUBECTL="kubectl --context $CTX"
# Admin creds = the post-install hook-set password (manifests/sonar-admin-secret.yaml),
# NOT the default admin/admin (which is changed away on first startup).
ADMIN_PW="$($KUBECTL -n "$SONAR_NS" get secret sonar-admin-password -o jsonpath='{.data.password}' | base64 -d)"
ADMIN="admin:${ADMIN_PW}"

echo "==> Waiting for SonarQube to be ready"
$KUBECTL -n "$SONAR_NS" rollout status deploy/sonar --timeout=600s
for _ in $(seq 1 60); do
  st="$(curl -fsSLk -m 10 -u "$ADMIN" "$SONAR_API/api/system/status" 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/')"
  [ "$st" = "UP" ] && break
  echo "    system status=${st:-<none>}; waiting..."; sleep 5
done
[ "${st:-}" = "UP" ] || { echo "!! SonarQube API never reached UP at $SONAR_API" >&2; exit 1; }

echo "==> Waiting for the operator-created ci-user"
LOGIN="ci-user"
for _ in $(seq 1 30); do
  found="$(curl -fsSLk -m 10 -u "$ADMIN" "$SONAR_API/api/users/search?q=ci-user" 2>/dev/null | grep -o '"login":"ci-user"' | head -1 || true)"
  [ -n "$found" ] && break
  echo "    ci-user not reconciled yet; waiting..."; sleep 5
done
if [ -z "${found:-}" ]; then
  echo "    (ci-user not found — falling back to an admin-owned token)"; LOGIN="admin"
fi

echo "==> Minting a SonarQube token (login=$LOGIN) for the ci-sonarqube secret"
# Revoke any prior token of this name so re-runs are idempotent, then generate.
curl -fsSLk -m 10 -u "$ADMIN" -X POST "$SONAR_API/api/user_tokens/revoke" \
  --data-urlencode "name=krci-ci" --data-urlencode "login=$LOGIN" >/dev/null 2>&1 || true
TOKEN="$(curl -fsSLk -m 10 -u "$ADMIN" -X POST "$SONAR_API/api/user_tokens/generate" \
  --data-urlencode "name=krci-ci" --data-urlencode "login=$LOGIN" 2>/dev/null \
  | grep -o '"token":"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/')"
[ -z "${TOKEN:-}" ] && { echo "!! failed to mint a SonarQube token" >&2; exit 1; }

echo "==> Creating the ci-sonarqube integration secret in ns/$NS"
cat <<EOF | $KUBECTL apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ci-sonarqube
  namespace: ${NS}
  labels:
    app.edp.epam.com/integration-secret: "true"
    app.edp.epam.com/secret-type: "sonar"
type: Opaque
stringData:
  url: "${SONAR_SVC_URL}"
  token: "${TOKEN}"
EOF

# The Portal's Sonar client needs SONAR_TOKEN (only minted now); patch it into the
# Portal secret + restart. Skipped if the Portal secret isn't present.
if $KUBECTL -n "$NS" get secret krci-portal-secret >/dev/null 2>&1; then
  echo "==> Wiring SONAR_TOKEN into the in-cluster Portal (secret/krci-portal-secret) + restart"
  $KUBECTL -n "$NS" patch secret krci-portal-secret --type merge \
    -p "{\"stringData\":{\"SONAR_TOKEN\":\"${TOKEN}\"}}"
  $KUBECTL -n "$NS" rollout restart deploy/krci-portal >/dev/null 2>&1 || true
fi

echo ""
echo "==> sonar-integrate done."
echo "    Integration: secret/ci-sonarqube (ns $NS) -> $SONAR_SVC_URL  (token for '$LOGIN')"
echo "    UI         : $SONAR_API   (user admin; password via 'make status')"
echo "    Validate   : curl -u <token>: $SONAR_API/api/authentication/validate"
