#!/usr/bin/env bash
# Phase: bring up self-hosted GitLab and everything KRCI needs BEFORE the platform
# chart installs. Runs before `make krci`. Pairs with scripts/gitlab-integrate.sh
# (post-krci). The GitServer + EventListener + Ingress are NOT created here — the
# edp-install chart renders them from `edp-tekton.gitServers` in values; this script
# only provisions the GitLab instance + the credentials/secrets the chart references.
#
# Split-horizon DNS: both hostnames resolve to 127.0.0.1 for the browser but must
# reach in-cluster services for pods. CoreDNS rewrites (both added here; the EL host
# is deterministic = el-<gitserver>-<ns>.<wildcard>):
#   - gitlab.<wildcard>          -> gitlab.gitlab.svc            (operator -> GitLab API/clone/SSH)
#   - el-gitlab-krci.<wildcard>  -> ingress-nginx controller     (GitLab -> webhook EventListener)
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
GL_NS="gitlab"
WILDCARD="${WILDCARD:-127.0.0.1.nip.io}"
GL_HOST="gitlab.${WILDCARD}"
GS_NAME="gitlab"                          # must match the key in edp-tekton.gitServers
EL_HOST="el-${GS_NAME}-${NS}.${WILDCARD}" # deterministic EventListener ingress host
# Predictable root password (local only). Set via the Makefile GITLAB_ROOT_PASSWORD var;
# keep this fallback in sync with the Makefile default. Applied on the FIRST DB seed.
GL_ROOT_PW="${GITLAB_ROOT_PASSWORD:-KrciLocal_2026!}"
KUBECTL="kubectl --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

ensure_coredns_rewrite() {
  local host="$1" target="$2"
  if $KUBECTL -n kube-system get configmap coredns -o yaml | grep -q "rewrite name ${host} "; then
    echo "    CoreDNS rewrite for ${host} already present"; return 0
  fi
  echo "    + CoreDNS rewrite ${host} -> ${target}"
  $KUBECTL -n kube-system get configmap coredns -o json \
    | HOST="$host" TARGET="$target" python3 -c "import json,os,sys
d=json.load(sys.stdin); c=d['data']['Corefile']
ins='    rewrite name %s %s\n' % (os.environ['HOST'], os.environ['TARGET'])
d['data']['Corefile']=c.replace('ready\n','ready\n'+ins,1) if 'ready\n' in c else c.replace('{\n','{\n'+ins,1)
print(json.dumps(d))" \
    | $KUBECTL apply -f -
  COREDNS_CHANGED=1
}

echo "==> Ensuring self-signed TLS cert for $GL_HOST (secret gitlab-tls)"
# The operator's GitLab REST client always uses https://, so GitLab serves TLS with
# this self-signed cert (also usable as its own CA). Must exist before the Deployment.
$KUBECTL get ns "$GL_NS" >/dev/null 2>&1 || $KUBECTL create ns "$GL_NS"
if ! $KUBECTL -n "$GL_NS" get secret gitlab-tls >/dev/null 2>&1; then
  CRT="$(mktemp)"; KEY="$(mktemp)"; CFG="$(mktemp)"
  cat > "$CFG" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ${GL_HOST}
[v3]
subjectAltName = DNS:${GL_HOST}
basicConstraints = critical, CA:TRUE
EOF
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -keyout "$KEY" -out "$CRT" -config "$CFG" >/dev/null 2>&1
  $KUBECTL -n "$GL_NS" create secret tls gitlab-tls --cert="$CRT" --key="$KEY" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  rm -f "$CRT" "$KEY" "$CFG"
else
  echo "    secret gitlab-tls already present"
fi

echo "==> Setting the predictable root password (secret gitlab-root-password)"
# Consumed by gitlab.yaml -> GITLAB_ROOT_PASSWORD env -> gitlab_rails['initial_root_password'].
# Must exist BEFORE the Deployment so the first reconfigure seeds root with it.
$KUBECTL -n "$GL_NS" create secret generic gitlab-root-password \
  --from-literal=password="$GL_ROOT_PW" \
  --dry-run=client -o yaml | $KUBECTL apply -f -

echo "==> Deploying GitLab CE (this is heavy; first boot 3-6 min)"
$KUBECTL apply -f "$HERE/manifests/gitlab.yaml"

echo "==> Ensuring namespace $NS exists (for the credential secrets the chart references)"
$KUBECTL get ns "$NS" >/dev/null 2>&1 || $KUBECTL create ns "$NS"

echo "==> CoreDNS split-horizon rewrites (gitlab host -> svc; EL host -> ingress-nginx)"
$KUBECTL -n kube-system get configmap coredns -o yaml > /tmp/coredns.bak.yaml
COREDNS_CHANGED=0
ensure_coredns_rewrite "$GL_HOST" "gitlab.${GL_NS}.svc.cluster.local"
ensure_coredns_rewrite "$EL_HOST" "ingress-nginx-controller.ingress-nginx.svc.cluster.local"
if [ "$COREDNS_CHANGED" = "1" ]; then $KUBECTL -n kube-system rollout restart deploy/coredns; fi

echo "==> Waiting for GitLab to become healthy (polling /-/health)..."
$KUBECTL -n $GL_NS rollout status deploy/gitlab --timeout=900s
$KUBECTL -n $GL_NS wait --for=condition=Ready pod -l app=gitlab --timeout=900s
POD="$($KUBECTL -n $GL_NS get pod -l app=gitlab -o jsonpath='{.items[0].metadata.name}')"
echo "==> GitLab pod: $POD"

echo "==> Waiting for the GitLab API + SSH to actually serve (not just /-/health)"
# /-/health (liveness) != API/gitlab-shell ready. The chart-rendered GitServer's
# connection check (SSH:32222 + API) needs both up so it connects on first reconcile.
for _ in $(seq 1 90); do
  api="$($KUBECTL -n $GL_NS exec "$POD" -- curl -sk -o /dev/null -w '%{http_code}' https://localhost/api/v4/version 2>/dev/null || echo 000)"
  ssh_up="$($KUBECTL -n $GL_NS exec "$POD" -- bash -c 'timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/22" 2>/dev/null && echo ok' 2>/dev/null || true)"
  case "$api" in 200|401) [ "$ssh_up" = "ok" ] && { echo "    GitLab API ($api) + SSH ready"; break; };; esac
  sleep 5
done

echo "    Root login: user 'root' / password '$GL_ROOT_PW' (from secret gitlab-root-password)"
echo "    (set on first DB seed; on an existing data PVC reset via:"
echo "     kubectl -n $GL_NS exec $POD -- gitlab-rake \"gitlab:password:reset[root]\")"

echo "==> Tuning instance settings (allow local webhooks; disable Auto DevOps)"
# allow_local_requests…: GitLab blocks webhooks to private IPs by default, which would
#   stop the merge_request hook reaching the in-cluster EventListener.
# auto_devops_enabled=false: with it ON (GitLab's default), every codebase project the
#   operator creates has no .gitlab-ci.yml, so GitLab auto-generates an "Auto DevOps"
#   CI pipeline (build/test/code_quality/container_scanning/… ~8 jobs). There are no
#   GitLab runners here, so those jobs hang "stuck" forever — pure noise next to the
#   only status KRCI cares about, the "Review Pipeline" external commit status the
#   gitlab-set-status task posts. Disabling the instance default means new projects
#   inherit Auto DevOps OFF. (Existing projects inherit too, unless explicitly toggled.)
$KUBECTL -n $GL_NS exec "$POD" -- gitlab-rails runner '
s = ApplicationSetting.current
s.update!(allow_local_requests_from_web_hooks_and_services: true, auto_devops_enabled: false)' >/dev/null 2>&1 || \
  echo "    (warn) could not update instance settings; set them in Admin -> Settings"

echo "==> Provisioning the '$NS' group (Codebases live under it, not root's namespace)"
$KUBECTL -n $GL_NS exec "$POD" -- gitlab-rails runner "
root = User.find_by_username('root')
unless Group.find_by_full_path('$NS')
  Groups::CreateService.new(root, name: '$NS', path: '$NS', visibility_level: Gitlab::VisibilityLevel::PRIVATE).execute
end
g = Group.find_by_full_path('$NS')
puts \"group $NS: id=#{g&.id} persisted=#{g&.persisted?}\"" 2>&1 | grep -iE "group $NS:" || \
  echo "    (warn) could not provision group '$NS'"

echo "==> Creating a personal access token for 'root' (idempotent: revokes old 'krci' tokens)"
TOKEN="$($KUBECTL -n $GL_NS exec "$POD" -- gitlab-rails runner '
u = User.find_by_username("root")
u.personal_access_tokens.where(name: "krci").update_all(revoked: true)
t = u.personal_access_tokens.create!(scopes: ["api","read_repository","write_repository"], name: "krci", expires_at: 365.days.from_now)
t.set_token(t.token); t.save!
puts t.token' 2>/dev/null | tail -1)"
echo "    PAT: ${TOKEN:0:6}… (stored in secret)"

echo "==> Generating an SSH key for KubeRocketCI <-> GitLab (idempotent: replaces old 'krci' key)"
TMPKEY="$(mktemp -u)"
ssh-keygen -t ed25519 -N "" -f "$TMPKEY" -C "krci@local" >/dev/null
$KUBECTL -n $GL_NS exec -i "$POD" -- gitlab-rails runner "
u = User.find_by_username('root')
u.keys.where(title: 'krci').destroy_all
u.keys.create!(title: 'krci', key: '$(cat "$TMPKEY".pub)')" >/dev/null 2>&1 || true

WEBHOOK_SECRET="$(openssl rand -hex 20)"
echo "==> Creating git credentials secret (ci-gitlab) in ns/$NS — referenced by edp-tekton.gitServers"
# Keys (see `kubectl explain gitserver.spec`): token (PAT), username (overrides
# gitUser), id_rsa (SSH key), secretString (webhook X-Gitlab-Token).
$KUBECTL -n "$NS" create secret generic ci-gitlab \
  --from-literal=token="$TOKEN" \
  --from-literal=username=root \
  --from-literal=secretString="$WEBHOOK_SECRET" \
  --from-file=id_rsa="$TMPKEY" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
rm -f "$TMPKEY" "$TMPKEY.pub"

echo "==> Registry credentials: '$NS' group deploy token -> kaniko-docker-config (ns/$NS)"
# KRCI reuses the GitLab Container Registry (:5050). Mint a group deploy token
# (read+write registry) via the API on the pod's localhost (revoke old ones first).
DT_JSON="$($KUBECTL -n $GL_NS exec "$POD" -- bash -c "
for id in \$(curl -sk -H 'PRIVATE-TOKEN: $TOKEN' https://localhost/api/v4/groups/$NS/deploy_tokens | grep -o '\"id\":[0-9]*' | grep -o '[0-9]*'); do
  curl -sk -X DELETE -H 'PRIVATE-TOKEN: $TOKEN' https://localhost/api/v4/groups/$NS/deploy_tokens/\$id >/dev/null
done
curl -sk -X POST -H 'PRIVATE-TOKEN: $TOKEN' -H 'Content-Type: application/json' \
  -d '{\"name\":\"krci-registry\",\"username\":\"krci-registry\",\"scopes\":[\"read_registry\",\"write_registry\"]}' \
  https://localhost/api/v4/groups/$NS/deploy_tokens
")"
REG_TOKEN="$(printf '%s' "$DT_JSON" | grep -o '"token":"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/')"
if [ -n "$REG_TOKEN" ]; then
  $KUBECTL -n "$NS" create secret docker-registry kaniko-docker-config \
    --docker-server="${GL_HOST}:5050" --docker-username=krci-registry --docker-password="$REG_TOKEN" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  # `regcred` = the image PULL secret KRCI's cd-pipeline-operator copies into each deploy
  # namespace as the workload imagePullSecret. The Stage reconcile chain fails
  # ("failed to get regcred secret") without it, so the deploy pipeline's pre-deploy step
  # can't find the per-stage configmap. Same registry creds as kaniko (token has read_registry).
  $KUBECTL -n "$NS" create secret docker-registry regcred \
    --docker-server="${GL_HOST}:5050" --docker-username=krci-registry --docker-password="$REG_TOKEN" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
else
  echo "    (warn) could not mint registry deploy token; create kaniko-docker-config/regcred manually"
fi

echo "==> Package registry: '$NS' group deploy token -> ci-nexus (ns/$NS)"
# The edp-tekton maven/npm/python build tasks read secret 'ci-nexus' (keys
# username/password/url). KRCI here has no Nexus, so point it at GitLab's Package
# Registry. Separate group deploy token with PACKAGE scopes (krci-registry above is
# container-registry only). Delete only prior 'krci-packages' tokens (the krci-registry
# block above already delete-all's; we must not clobber the token it just created).
PKG_JSON="$($KUBECTL -n $GL_NS exec "$POD" -- bash -c "
for id in \$(curl -sk -H 'PRIVATE-TOKEN: $TOKEN' https://localhost/api/v4/groups/$NS/deploy_tokens | grep -o '\"id\":[0-9]*' | grep -o '[0-9]*'); do
  curl -sk -H 'PRIVATE-TOKEN: $TOKEN' https://localhost/api/v4/groups/$NS/deploy_tokens/\$id | grep -q '\"name\":\"krci-packages\"' \
    && curl -sk -X DELETE -H 'PRIVATE-TOKEN: $TOKEN' https://localhost/api/v4/groups/$NS/deploy_tokens/\$id >/dev/null
done
curl -sk -X POST -H 'PRIVATE-TOKEN: $TOKEN' -H 'Content-Type: application/json' \
  -d '{\"name\":\"krci-packages\",\"username\":\"krci-packages\",\"scopes\":[\"read_package_registry\",\"write_package_registry\"]}' \
  https://localhost/api/v4/groups/$NS/deploy_tokens
")"
PKG_TOKEN="$(printf '%s' "$PKG_JSON" | grep -o '"token":"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/')"
if [ -n "$PKG_TOKEN" ]; then
  $KUBECTL -n "$NS" create secret generic ci-nexus \
    --from-literal=username=krci-packages \
    --from-literal=password="$PKG_TOKEN" \
    --from-literal=url="https://${GL_HOST}" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  $KUBECTL -n "$NS" label secret ci-nexus \
    app.edp.epam.com/secret-type=nexus app.edp.epam.com/integration-secret=true --overwrite >/dev/null
else
  echo "    (warn) could not mint package deploy token; create secret ci-nexus manually"
fi

echo "==> Teaching the kind node's containerd to pull from the GitLab registry"
# Deployed workloads reference gitlab.127.0.0.1.nip.io:5050/<group>/<repo>, but containerd
# on the NODE resolves that host to 127.0.0.1 (nip.io) — the CoreDNS rewrite only helps
# in-cluster pods, so image pulls fail with "dial 127.0.0.1:5050: connection refused".
# Drop a hosts.toml that mirrors the registry host to the GitLab service ClusterIP (which
# the node reaches via kube-proxy) and skips the self-signed cert. config_path is enabled
# in kind/cluster.yaml, so certs.d is read per-pull (no containerd restart needed).
NODE="${KIND_NODE:-${CLUSTER:-krci}-control-plane}"
GL_CIP="$($KUBECTL -n "$GL_NS" get svc gitlab -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
if [ -n "$GL_CIP" ] && command -v docker >/dev/null 2>&1 && docker inspect "$NODE" >/dev/null 2>&1; then
  docker exec "$NODE" bash -c "
    mkdir -p '/etc/containerd/certs.d/${GL_HOST}:5050'
    cat > '/etc/containerd/certs.d/${GL_HOST}:5050/hosts.toml' <<EOF
server = \"https://${GL_HOST}:5050\"
[host.\"https://${GL_CIP}:5050\"]
  capabilities = [\"pull\", \"resolve\"]
  skip_verify = true
EOF"
  echo "    containerd certs.d -> ${GL_HOST}:5050 mirrors https://${GL_CIP}:5050 (skip_verify)"
else
  echo "    (warn) could not configure node containerd (node '$NODE' or ClusterIP missing); image pulls of deployed apps may fail"
fi

echo "==> Publishing the GitLab CA: secret custom-ca-certificates (kaniko) + cm gitlab-ca (operator)"
# Same self-signed cert, consumed two ways post-krci: kaniko trusts the registry via
# secret custom-ca-certificates (key ca.crt; edp-tekton.kaniko.customCert=true), and
# scripts/gitlab-integrate.sh mounts cm gitlab-ca into the codebase-operator.
$KUBECTL -n $GL_NS get secret gitlab-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/gitlab-ca.crt
$KUBECTL -n "$NS" create secret generic custom-ca-certificates --from-file=ca.crt=/tmp/gitlab-ca.crt \
  --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n "$NS" create configmap gitlab-ca --from-file=gitlab-ca.crt=/tmp/gitlab-ca.crt \
  --dry-run=client -o yaml | $KUBECTL apply -f -
rm -f /tmp/gitlab-ca.crt

echo ""
echo "==> gitlab-up done."
echo "    GitLab UI : https://$GL_HOST   (self-signed cert)"
echo "    User      : root"
echo "    Password  : $GL_ROOT_PW   (local only — also shown by 'make status')"
echo "    Next: 'make krci' renders the GitServer/EventListener/Ingress from values,"
echo "          then 'make gitlab-integrate' applies the operator CA + task fixes + GitOps repo."
