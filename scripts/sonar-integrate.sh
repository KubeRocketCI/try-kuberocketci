#!/usr/bin/env bash
# Post-KRCI SonarQube integration. Requires `make sonar` (SonarQube + operator + CRs up)
# and `make krci` (namespace krci exists). Mints a token for the operator-created
# `ci-user` and stores it as the `ci-sonarqube` integration secret the edp-tekton
# `sonar` task reads.
# Docs: https://docs.kuberocketci.io/docs/operator-guide/code-quality/sonarqube
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
SONAR_NS="${SONAR_NS:-sonar}"
WILDCARD="${WILDCARD:-127.0.0.1.nip.io}"
SONAR_HOST="sonar.${WILDCARD}"
# https directly (self-signed -> -k). The ingress redirects http -> https, and curl
# drops the Authorization header on a followed redirect that changes port:
# authenticated calls become anonymous.
SONAR_API="https://${SONAR_HOST}"
SONAR_SVC_URL="http://sonar.${SONAR_NS}.svc:9000"   # in-cluster URL the sonar task uses
KUBECTL="kubectl --context $CTX"
# Admin password: set by the chart's post-install hook from
# manifests/sonar-admin-secret.yaml (default admin/admin is rotated on first startup).
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
# A prior token of this name is revoked first; generate is not idempotent.
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

# The Portal's Sonar client reads SONAR_TOKEN from krci-portal-secret; the token exists
# only from this point. Patched in and the Portal restarted; skipped without the secret.
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
