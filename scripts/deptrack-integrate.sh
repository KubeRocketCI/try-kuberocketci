#!/usr/bin/env bash
# Optional post-KRCI Dependency-Track integration, not part of `make testbed`. Requires
# `make deptrack` (Dependency-Track up) and `make krci` (namespace krci exists).
#   * admin password: the forced first-login change, stored in secret/deptrack-admin-password.
#   * team krci-ci (the documented CI permissions) -> secret/ci-dependency-track, read by the
#     edp-tekton `security` task (cdxgen SBOM upload, project=<codebase>, version=<branch>).
#   * team krci-portal (read-only) -> DEPENDENCY_TRACK_API_KEY in secret/krci-portal-secret,
#     read by the Portal SCA endpoints (`krci sca`).
#   * vulnerability sources: OSV on for the testbed codebase ecosystems (off upstream);
#     NVD stays at the upstream default. A BOM is analysed against the data mirrored at
#     upload time: scan after the mirror finishes.
# Docs: https://docs.kuberocketci.io/docs/operator-guide/devsecops/dependency-track
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
DEPTRACK_NS="${DEPTRACK_NS:-dependency-track}"
WILDCARD="${WILDCARD:-127.0.0.1.nip.io}"
DT_API="https://deptrack.${WILDCARD}"
DT_SVC_URL="http://deptrack-api-server.${DEPTRACK_NS}:8080"
OSV_ECOSYSTEMS="${OSV_ECOSYSTEMS:-Go;PyPI}"
KUBECTL="kubectl --context $CTX"

CI_PERMISSIONS="BOM_UPLOAD PROJECT_CREATION_UPLOAD VIEW_PORTFOLIO"
PORTAL_PERMISSIONS="VIEW_PORTFOLIO VIEW_VULNERABILITY VIEW_POLICY_VIOLATION"

json() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

echo "==> Waiting for the Dependency-Track API"
$KUBECTL -n "$DEPTRACK_NS" rollout status deploy/deptrack-api-server --timeout=600s
for _ in $(seq 1 60); do
  curl -fsk -m 10 "$DT_API/api/version" >/dev/null 2>&1 && break
  echo "    API not ready; waiting..."; sleep 5
done
curl -fsk -m 10 "$DT_API/api/version" >/dev/null || { echo "!! Dependency-Track API never answered at $DT_API" >&2; exit 1; }

echo "==> Admin password (secret/deptrack-admin-password)"
if ! $KUBECTL -n "$DEPTRACK_NS" get secret deptrack-admin-password >/dev/null 2>&1; then
  $KUBECTL -n "$DEPTRACK_NS" create secret generic deptrack-admin-password \
    --from-literal=username=admin --from-literal=password="Krci-$(openssl rand -hex 8)"
fi
ADMIN_PW="$($KUBECTL -n "$DEPTRACK_NS" get secret deptrack-admin-password -o jsonpath='{.data.password}' | base64 -d)"

login() {
  curl -fsk -m 10 -X POST "$DT_API/api/v1/user/login" \
    --data-urlencode "username=admin" --data-urlencode "password=$1" 2>/dev/null
}

JWT="$(login "$ADMIN_PW" || true)"
if [ -z "$JWT" ]; then
  echo "    first login: replacing the default admin password"
  curl -fsk -m 10 -X POST "$DT_API/api/v1/user/forceChangePassword" \
    --data-urlencode "username=admin" --data-urlencode "password=admin" \
    --data-urlencode "newPassword=$ADMIN_PW" --data-urlencode "confirmPassword=$ADMIN_PW" >/dev/null
  JWT="$(login "$ADMIN_PW")"
fi
[ -n "$JWT" ] || { echo "!! admin login failed" >&2; exit 1; }

api() {
  local method="$1" path="$2"; shift 2
  curl -fsk -m 30 -X "$method" "$DT_API/api/v1/$path" -H "Authorization: Bearer $JWT" "$@"
}

# key_works KEY: true when KEY can read the portfolio.
key_works() {
  [ -n "$1" ] && [ "$(curl -sk -m 10 -o /dev/null -w '%{http_code}' -H "X-Api-Key: $1" \
    "$DT_API/api/v1/project?pageSize=1")" = "200" ]
}

# team_key NAME "PERMS..." EXISTING_KEY: ensures team NAME exists and holds PERMS, and
# prints a working API key, reusing EXISTING_KEY when it still works.
team_key() {
  local name="$1" perms="$2" existing="$3" uuid perm
  uuid="$(api GET team | NAME="$name" json 'import os; print(next((t["uuid"] for t in d if t["name"]==os.environ["NAME"]), ""))')"
  if [ -z "$uuid" ]; then
    uuid="$(api PUT team -H 'Content-Type: application/json' -d "{\"name\":\"$name\"}" | json 'print(d["uuid"])')"
  fi
  for perm in $perms; do
    api POST "permission/$perm/team/$uuid" -o /dev/null -w '' 2>/dev/null || true
  done
  if key_works "$existing"; then
    echo "$existing"
  else
    api PUT "team/$uuid/key" | json 'print(d["key"])'
  fi
}

existing_secret_value() {
  $KUBECTL -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" 2>/dev/null | base64 -d 2>/dev/null || true
}

echo "==> Team krci-ci ($CI_PERMISSIONS)"
CI_KEY="$(team_key krci-ci "$CI_PERMISSIONS" "$(existing_secret_value ci-dependency-track token)")"
echo "==> Team krci-portal ($PORTAL_PERMISSIONS)"
PORTAL_KEY="$(team_key krci-portal "$PORTAL_PERMISSIONS" "$(existing_secret_value krci-portal-secret DEPENDENCY_TRACK_API_KEY)")"
[ -n "$CI_KEY" ] && [ -n "$PORTAL_KEY" ] || { echo "!! failed to mint API keys" >&2; exit 1; }

echo "==> Vulnerability sources: OSV for $OSV_ECOSYSTEMS"
current="$(api GET configProperty | json 'print(next((p.get("propertyValue") or "" for p in d if p["groupName"]=="vuln-source" and p["propertyName"]=="google.osv.enabled"), ""))')"
if [ "$(tr ';' '\n' <<<"$current" | sort | paste -sd';' -)" != "$(tr ';' '\n' <<<"$OSV_ECOSYSTEMS" | sort | paste -sd';' -)" ]; then
  api POST configProperty/aggregate -H 'Content-Type: application/json' -o /dev/null -d "[
    {\"groupName\":\"vuln-source\",\"propertyName\":\"google.osv.enabled\",\"propertyValue\":\"$OSV_ECOSYSTEMS\"}
  ]"
  # The OSV mirror runs at startup and then every 24h; restart to mirror now. /data is an
  # emptyDir, so the NVD feeds are mirrored again too (a few minutes).
  echo "    restarting the API server to start the OSV mirror"
  $KUBECTL -n "$DEPTRACK_NS" rollout restart deploy/deptrack-api-server >/dev/null
  $KUBECTL -n "$DEPTRACK_NS" rollout status deploy/deptrack-api-server --timeout=600s
fi

echo "==> Creating the ci-dependency-track integration secret in ns/$NS"
cat <<EOF | $KUBECTL apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ci-dependency-track
  namespace: ${NS}
  labels:
    app.edp.epam.com/integration-secret: "true"
    app.edp.epam.com/secret-type: "dependency-track"
type: Opaque
stringData:
  url: "${DT_SVC_URL}"
  token: "${CI_KEY}"
EOF

# Dependency-Track is optional: the platform values do not configure it. The Portal reads
# DEPENDENCY_TRACK_URL from portal-config and DEPENDENCY_TRACK_API_KEY from
# krci-portal-secret; `make krci` re-renders portal-config, so run this target again after it.
if $KUBECTL -n "$NS" get secret krci-portal-secret >/dev/null 2>&1; then
  echo "==> Wiring Dependency-Track into the in-cluster Portal + restart"
  $KUBECTL -n "$NS" patch configmap portal-config --type merge -p "{\"data\":{
    \"DEPENDENCY_TRACK_URL\":\"${DT_SVC_URL}\",\"DEPENDENCY_TRACK_WEB_URL\":\"${DT_API}\"}}"
  $KUBECTL -n "$NS" patch secret krci-portal-secret --type merge \
    -p "{\"stringData\":{\"DEPENDENCY_TRACK_API_KEY\":\"${PORTAL_KEY}\"}}"
  $KUBECTL -n "$NS" rollout restart deploy/krci-portal >/dev/null
  $KUBECTL -n "$NS" rollout status deploy/krci-portal --timeout=300s
fi

echo ""
echo "==> deptrack-integrate done."
echo "    Integration: secret/ci-dependency-track (ns $NS) -> $DT_SVC_URL  (team krci-ci)"
echo "    Portal     : DEPENDENCY_TRACK_API_KEY (team krci-portal)"
echo "    UI         : $DT_API   (user admin; password via 'make status')"
echo "    Scan       : run the gitlab-security-scan pipeline for a codebase, then 'krci sca list'"
