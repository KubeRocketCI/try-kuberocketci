#!/usr/bin/env bash
# Optional DefectDojo integration, not part of `make testbed`. Requires `make defectdojo`.
# Each consumer is wired only when it exists; re-run after `make krci` (re-renders portal-config).
#   * admin API v2 token (POST /api/v2/api-token-auth/ with the chart-generated admin password in
#     secret defectdojo/defectdojo, key DD_ADMIN_PASSWORD). The token is stable per user.
#   * CI: secret/ci-defectdojo (keys url, token) in ns krci, read by the edp-tekton `security` and
#     `image-scan` tasks. Only when ns krci exists. url = the Service URL.
#   * Portal: DEFECTDOJO_URL / DEFECTDOJO_WEB_URL / DEFECTDOJO_CLUSTER_NAME in cm/portal-config and
#     DEFECTDOJO_API_KEY in secret/krci-portal-secret. Only when both exist.
#   * krci-security-operator: secret/defectdojo-credentials (keys url, token) in ns krci-security,
#     created only when absent: a token put there by hand (for example one with minimal
#     permissions) is kept; delete the Secret to get the admin token back. url =
#     http://defectdojo.<wildcard>: the operator client verifies TLS and has no insecure option. The
#     host resolves on the host through nip.io and in pods through a CoreDNS rewrite to
#     ingress-nginx added here. Then Helm release krci-security-operator in ns krci-security:
#     SECURITY_OPERATOR_VERSION from SECURITY_OPERATOR_REPO, values/krci-security-operator.yaml,
#     clusterName = DEFECTDOJO_CLUSTER_NAME. SECURITY_OPERATOR_CHART (local chart directory) replaces
#     the repo chart; SECURITY_OPERATOR_IMAGE (<repo>:<tag>, for example kind-loaded) replaces the
#     chart image. Scale it to 0 to run the operator from the host (`make run` in its repo).
#   * Trivy scan jobs: secret krci/regcred (the KRCI registry pull secret, copied into every Stage)
#     copied to secret/krci-regcred in ns trivy-system and added to the imagePullSecrets of
#     ServiceAccount trivy-operator, which the rootfs scan pods use. Since Kubernetes 1.35 the kubelet
#     lets a pod use a cached image pulled with a pull secret only when the pod carries matching
#     credentials; without them the scans of Stage images end in ErrImageNeverPull. The chart has no
#     ServiceAccount imagePullSecrets value; Helm keeps the field. Only when both namespaces exist.
# `--remove`: uninstall the operator, delete ns krci-security and the other consumers' credentials;
# used by `make defectdojo-down`.
# Docs: https://docs.kuberocketci.io/docs/operator-guide/devsecops/defectdojo
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
DEFECTDOJO_NS="${DEFECTDOJO_NS:-defectdojo}"
SECURITY_NS="${SECURITY_NS:-krci-security}"
TRIVY_NS="${TRIVY_NS:-trivy-system}"
TRIVY_SA=trivy-operator
SCAN_PULL_SECRET=krci-regcred
WILDCARD="${WILDCARD:-127.0.0.1.nip.io}"
# Must equal the operator's CLUSTER_NAME (operator default in-cluster).
CLUSTER_NAME="${DEFECTDOJO_CLUSTER_NAME:-in-cluster}"
OPERATOR_SECRET="${DEFECTDOJO_SECRET_NAME:-defectdojo-credentials}"
OPERATOR=krci-security-operator
SECURITY_OPERATOR_VERSION="${SECURITY_OPERATOR_VERSION:-}"
SECURITY_OPERATOR_REPO="${SECURITY_OPERATOR_REPO:-epamedp-snapshot}"
SECURITY_OPERATOR_CHART="${SECURITY_OPERATOR_CHART:-}"
SECURITY_OPERATOR_IMAGE="${SECURITY_OPERATOR_IMAGE:-}"
HELM="helm --kube-context $CTX"
DD_HOST="defectdojo.${WILDCARD}"
DD_URL="http://${DD_HOST}"
DD_SVC_URL="http://defectdojo-django.${DEFECTDOJO_NS}"
KUBECTL="kubectl --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/lib/coredns.sh"

PORTAL_KEYS="DEFECTDOJO_URL DEFECTDOJO_WEB_URL DEFECTDOJO_CLUSTER_NAME"

if [ "${1:-}" = "--remove" ]; then
  echo "==> Removing $OPERATOR and the DefectDojo credentials"
  $HELM uninstall "$OPERATOR" -n "$SECURITY_NS" --ignore-not-found --wait --timeout 300s
  $KUBECTL delete namespace "$SECURITY_NS" --ignore-not-found --wait --timeout=300s
  if $KUBECTL get ns "$NS" >/dev/null 2>&1; then
    $KUBECTL -n "$NS" delete secret ci-defectdojo --ignore-not-found
    if $KUBECTL -n "$NS" get configmap portal-config >/dev/null 2>&1 \
      && $KUBECTL -n "$NS" get secret krci-portal-secret >/dev/null 2>&1 \
      && [ -n "$($KUBECTL -n "$NS" get secret krci-portal-secret -o jsonpath='{.data.DEFECTDOJO_API_KEY}')" ]; then
      echo "    removing the Portal settings + restart"
      $KUBECTL -n "$NS" patch configmap portal-config --type merge \
        -p '{"data":{"DEFECTDOJO_URL":null,"DEFECTDOJO_WEB_URL":null,"DEFECTDOJO_CLUSTER_NAME":null}}'
      $KUBECTL -n "$NS" patch secret krci-portal-secret --type merge -p '{"data":{"DEFECTDOJO_API_KEY":null}}'
      $KUBECTL -n "$NS" rollout restart deploy/krci-portal >/dev/null
    fi
  fi
  exit 0
fi

# dd_curl ARGS...: curl against the ingress. --resolve and --noproxy make it work where nip.io
# does not resolve (DNS-rebind protection, sandboxes).
dd_curl() {
  curl -fsS --noproxy '*' --resolve "${DD_HOST}:80:127.0.0.1" -m 30 "$@"
}

echo "==> Waiting for DefectDojo"
$KUBECTL -n "$DEFECTDOJO_NS" rollout status deploy/defectdojo-django --timeout=600s
for _ in $(seq 1 60); do
  dd_curl -o /dev/null "${DD_URL}/login?force_login_form" 2>/dev/null && break
  echo "    UI not ready; waiting..."; sleep 5
done
dd_curl -o /dev/null "${DD_URL}/login?force_login_form" \
  || { echo "!! DefectDojo never answered at $DD_URL (ingress-nginx up? 'make ingress')" >&2; exit 1; }

echo "==> Admin API token"
ADMIN_PW="$($KUBECTL -n "$DEFECTDOJO_NS" get secret defectdojo -o jsonpath='{.data.DD_ADMIN_PASSWORD}' | base64 -d)"
[ -n "$ADMIN_PW" ] || { echo "!! secret/defectdojo has no DD_ADMIN_PASSWORD" >&2; exit 1; }
TOKEN="$(
  ADMIN_PW="$ADMIN_PW" python3 -c 'import json,os; print(json.dumps({"username":"admin","password":os.environ["ADMIN_PW"]}))' \
    | dd_curl -X POST -H 'Content-Type: application/json' --data-binary @- "${DD_URL}/api/v2/api-token-auth/" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
)" || true
[ -n "$TOKEN" ] || { echo "!! could not get an API token for admin" >&2; exit 1; }
dd_curl -o /dev/null -H "Authorization: Token $TOKEN" "${DD_URL}/api/v2/user_profile/" \
  || { echo "!! the API token was rejected" >&2; exit 1; }

echo "==> CoreDNS: ${DD_HOST} -> ingress-nginx (pods reach the same URL as the host)"
COREDNS_CHANGED=0
ensure_coredns_rewrite "$DD_HOST" "ingress-nginx-controller.ingress-nginx.svc.cluster.local"
if [ "$COREDNS_CHANGED" = "1" ]; then
  $KUBECTL -n kube-system rollout restart deploy/coredns >/dev/null
  $KUBECTL -n kube-system rollout status deploy/coredns --timeout=120s
fi

# apply_credentials NAMESPACE NAME URL [LABEL=VALUE...]: Secret NAME with keys url, token.
apply_credentials() {
  local ns="$1" name="$2" url="$3"; shift 3
  {
    echo "apiVersion: v1"
    echo "kind: Secret"
    echo "metadata:"
    echo "  name: ${name}"
    echo "  namespace: ${ns}"
    if [ "$#" -gt 0 ]; then
      echo "  labels:"
      for l in "$@"; do echo "    ${l%%=*}: \"${l#*=}\""; done
    fi
    echo "type: Opaque"
    echo "stringData:"
    echo "  url: \"${url}\""
    echo "  token: \"${TOKEN}\""
  } | $KUBECTL apply -f - >/dev/null
  echo "    secret/${name} (ns ${ns}) -> ${url}"
}

echo "==> $OPERATOR credentials (ns $SECURITY_NS)"
$KUBECTL create namespace "$SECURITY_NS" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
if $KUBECTL -n "$SECURITY_NS" get secret "$OPERATOR_SECRET" >/dev/null 2>&1; then
  echo "    secret/${OPERATOR_SECRET} (ns ${SECURITY_NS}) exists: kept (delete it to get the admin token)"
else
  apply_credentials "$SECURITY_NS" "$OPERATOR_SECRET" "$DD_URL"
fi

echo "==> $OPERATOR (ns $SECURITY_NS)"
chart=("$SECURITY_OPERATOR_REPO/$OPERATOR" --version "$SECURITY_OPERATOR_VERSION" --devel)
source="$SECURITY_OPERATOR_VERSION"
image=()
if [ -n "$SECURITY_OPERATOR_CHART" ]; then
  chart=("$SECURITY_OPERATOR_CHART") source="$SECURITY_OPERATOR_CHART"
else
  [ -n "$SECURITY_OPERATOR_VERSION" ] || { echo "!! SECURITY_OPERATOR_VERSION is required" >&2; exit 1; }
fi
if [ -n "$SECURITY_OPERATOR_IMAGE" ]; then
  [[ "${SECURITY_OPERATOR_IMAGE##*/}" == *:* ]] || {
    echo "!! SECURITY_OPERATOR_IMAGE=$SECURITY_OPERATOR_IMAGE has no tag: use <repo>:<tag>" >&2
    exit 1
  }
  image=(--set image.repository="${SECURITY_OPERATOR_IMAGE%:*}" --set image.tag="${SECURITY_OPERATOR_IMAGE##*:}")
  source="$source, image $SECURITY_OPERATOR_IMAGE"
fi
$HELM upgrade --install "$OPERATOR" "${chart[@]}" -n "$SECURITY_NS" \
  -f "$HERE/values/krci-security-operator.yaml" ${image[@]+"${image[@]}"} \
  --set defectdojo.secretName="$OPERATOR_SECRET" --set clusterName="$CLUSTER_NAME" \
  --wait --timeout 5m >/dev/null
echo "    $OPERATOR $source ready"

PORTAL_CHANGED=0
if $KUBECTL get ns "$NS" >/dev/null 2>&1; then
  echo "==> Trivy scan pull secret (ns $TRIVY_NS)"
  if ! $KUBECTL get ns "$TRIVY_NS" >/dev/null 2>&1; then
    echo "    ns $TRIVY_NS absent (make defectdojo): skipped"
  elif ! $KUBECTL -n "$NS" get secret regcred >/dev/null 2>&1; then
    echo "    secret/regcred (ns $NS) absent (make gitlab-up): skipped"
  else
    $KUBECTL -n "$NS" get secret regcred -o json | SECRET="$SCAN_PULL_SECRET" NS_TO="$TRIVY_NS" python3 -c '
import json, os, sys
s = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": s["type"], "data": s["data"],
                  "metadata": {"name": os.environ["SECRET"], "namespace": os.environ["NS_TO"]}}))' \
      | $KUBECTL apply -f - >/dev/null
    sa_before="$($KUBECTL -n "$TRIVY_NS" get sa "$TRIVY_SA" -o jsonpath='{.imagePullSecrets}')"
    if $KUBECTL -n "$TRIVY_NS" get sa "$TRIVY_SA" -o jsonpath='{.imagePullSecrets[*].name}' | tr ' ' '\n' | grep -qx "$SCAN_PULL_SECRET"; then
      echo "    secret/$SCAN_PULL_SECRET synced; already on sa/$TRIVY_SA"
    elif [ -n "$($KUBECTL -n "$TRIVY_NS" get sa "$TRIVY_SA" -o jsonpath='{.imagePullSecrets}')" ]; then
      $KUBECTL -n "$TRIVY_NS" patch sa "$TRIVY_SA" --type json \
        -p "[{\"op\":\"add\",\"path\":\"/imagePullSecrets/-\",\"value\":{\"name\":\"$SCAN_PULL_SECRET\"}}]" >/dev/null
      echo "    secret/$SCAN_PULL_SECRET synced; added to sa/$TRIVY_SA"
    else
      $KUBECTL -n "$TRIVY_NS" patch sa "$TRIVY_SA" --type merge \
        -p "{\"imagePullSecrets\":[{\"name\":\"$SCAN_PULL_SECRET\"}]}" >/dev/null
      echo "    secret/$SCAN_PULL_SECRET synced; set on sa/$TRIVY_SA"
    fi
    if [ "$sa_before" != "$($KUBECTL -n "$TRIVY_NS" get sa "$TRIVY_SA" -o jsonpath='{.imagePullSecrets}')" ]; then
      # trivy-operator retries a failed scan only on a workload change or a restart.
      $KUBECTL -n "$TRIVY_NS" rollout restart deploy/trivy-operator >/dev/null
      $KUBECTL -n "$TRIVY_NS" rollout status deploy/trivy-operator --timeout=120s
    fi
  fi

  echo "==> CI integration secret (ns $NS)"
  apply_credentials "$NS" ci-defectdojo "$DD_SVC_URL" \
    app.edp.epam.com/integration-secret=true app.edp.epam.com/secret-type=defectdojo

  # The Portal reads DEFECTDOJO_URL (API, in-cluster), DEFECTDOJO_WEB_URL (links, browser) and
  # DEFECTDOJO_CLUSTER_NAME from portal-config and DEFECTDOJO_API_KEY from krci-portal-secret.
  if $KUBECTL -n "$NS" get configmap portal-config >/dev/null 2>&1 \
    && $KUBECTL -n "$NS" get secret krci-portal-secret >/dev/null 2>&1; then
    echo "==> Wiring DefectDojo into the in-cluster Portal"
    cm_value() { $KUBECTL -n "$NS" get configmap portal-config -o jsonpath="{.data.$1}"; }
    have_key="$($KUBECTL -n "$NS" get secret krci-portal-secret -o jsonpath='{.data.DEFECTDOJO_API_KEY}' | base64 -d)"
    if [ "$(cm_value DEFECTDOJO_URL)" != "$DD_SVC_URL" ] || [ "$(cm_value DEFECTDOJO_WEB_URL)" != "$DD_URL" ] \
      || [ "$(cm_value DEFECTDOJO_CLUSTER_NAME)" != "$CLUSTER_NAME" ] || [ "$have_key" != "$TOKEN" ]; then
      $KUBECTL -n "$NS" patch configmap portal-config --type merge -p "{\"data\":{
        \"DEFECTDOJO_URL\":\"${DD_SVC_URL}\",\"DEFECTDOJO_WEB_URL\":\"${DD_URL}\",
        \"DEFECTDOJO_CLUSTER_NAME\":\"${CLUSTER_NAME}\"}}" >/dev/null
      $KUBECTL -n "$NS" patch secret krci-portal-secret --type merge \
        -p "{\"stringData\":{\"DEFECTDOJO_API_KEY\":\"${TOKEN}\"}}" >/dev/null
      PORTAL_CHANGED=1
    else
      echo "    already wired"
    fi
  else
    echo "    cm/portal-config or secret/krci-portal-secret missing: Portal skipped"
  fi
else
  echo "==> ns $NS absent: CI secret and Portal skipped"
fi

if [ "$PORTAL_CHANGED" = "1" ]; then
  $KUBECTL -n "$NS" rollout restart deploy/krci-portal >/dev/null
  $KUBECTL -n "$NS" rollout status deploy/krci-portal --timeout=300s
fi

echo ""
echo "==> defectdojo-integrate done."
echo "    UI         : $DD_URL   (user admin; password via 'make status')"
echo "    Operator   : deploy/$OPERATOR (ns $SECURITY_NS), secret/${OPERATOR_SECRET} -> $DD_URL, cluster $CLUSTER_NAME"
echo "                 products: $CLUSTER_NAME/<namespace>; logs: kubectl -n $SECURITY_NS logs deploy/$OPERATOR"
echo "    CI         : secret/ci-defectdojo (ns $NS) -> $DD_SVC_URL"
echo "    Portal     : DEFECTDOJO_* (cluster name $CLUSTER_NAME)"
