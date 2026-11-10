#!/usr/bin/env bash
# Self-hosted GitLab plus everything KRCI needs before the platform chart installs.
# Runs before `make krci`; pairs with scripts/gitlab-integrate.sh (post-krci). The
# GitServer + EventListener + Ingress are rendered by the edp-install chart from
# `edp-tekton.gitServers`; this script provisions the GitLab instance and the
# credentials/secrets those values reference.
#
# Split-horizon DNS: both hostnames resolve to 127.0.0.1 for the browser and must reach
# in-cluster services for pods. CoreDNS rewrites added here (the EL host is
# deterministic: el-<gitserver>-<ns>.<wildcard>):
#   - gitlab.<wildcard>          -> gitlab.gitlab.svc            (operator -> GitLab API/clone/SSH)
#   - el-gitlab-krci.<wildcard>  -> ingress-nginx controller     (GitLab -> webhook EventListener)
#
# Extra CAs for GitLab outbound TLS: optional ConfigMap gitlab/trusted-certs, mounted at
# /etc/gitlab-trusted-certs-src and copied into /etc/gitlab/trusted-certs. GITLAB_TRUST_ONLY=1
# runs only this step: apply the GitLab manifest, wait for the mount to match the ConfigMap,
# copy, reconfigure when the set changed.
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
GL_NS="gitlab"
WILDCARD="${WILDCARD:-127.0.0.1.nip.io}"
GL_HOST="gitlab.${WILDCARD}"
GS_NAME="gitlab"                          # must match the key in edp-tekton.gitServers
EL_HOST="el-${GS_NAME}-${NS}.${WILDCARD}" # deterministic EventListener ingress host
# Root password (local only). The Makefile GITLAB_ROOT_PASSWORD var passes it; this
# fallback must equal the Makefile default. Applied on the first DB seed only.
GL_ROOT_PW="${GITLAB_ROOT_PASSWORD:-KrciLocal_2026!}"
KUBECTL="kubectl --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/lib/gitlab.sh"

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

# ensure_trusted_certs: sync /etc/gitlab-trusted-certs-src (ConfigMap mount) into /etc/gitlab/trusted-certs
# and run gitlab-ctl reconfigure when the set changed. Files the sync copied are listed in
# /var/opt/gitlab/trusted-certs.managed; other files in the directory are not touched.
ensure_trusted_certs() {
  local pod want have
  pod="$($KUBECTL -n $GL_NS get pod -l app=gitlab -o jsonpath='{.items[0].metadata.name}')"
  want="$($KUBECTL -n $GL_NS get configmap trusted-certs -o json 2>/dev/null \
    | python3 -I -c 'import json,sys; d=json.load(sys.stdin).get("data") or {}; sys.stdout.write("".join(d[k] for k in sorted(d)))' || true)"
  for _ in $(seq 1 40); do
    # Byte order, matching Python sorted(); ConfigMap keys contain no whitespace.
    have="$($KUBECTL -n $GL_NS exec "$pod" -- bash -c \
      'cd /etc/gitlab-trusted-certs-src 2>/dev/null || exit 0; for f in $(ls | LC_ALL=C sort); do cat "$f"; done' || true)"
    [ "$have" = "$want" ] && break
    sleep 3
  done
  [ "$have" = "$want" ] || { echo "FAIL /etc/gitlab-trusted-certs-src does not match ConfigMap gitlab/trusted-certs" >&2; return 1; }
  $KUBECTL -n $GL_NS exec "$pod" -- bash -c '
    set -e
    src=/etc/gitlab-trusted-certs-src dst=/etc/gitlab/trusted-certs list=/var/opt/gitlab/trusted-certs.managed
    mkdir -p "$dst"; touch "$list"; changed=0
    while read -r f; do
      [ -n "$f" ] && [ ! -e "$src/$f" ] && { rm -f "$dst/$f"; changed=1; }
    done <"$list"
    : >"$list.new"
    for p in "$src"/*; do
      [ -f "$p" ] || continue
      f="$(basename "$p")"; echo "$f" >>"$list.new"
      cmp -s "$p" "$dst/$f" || { cp "$p" "$dst/$f"; changed=1; }
    done
    mv "$list.new" "$list"
    if [ "$changed" = 0 ]; then echo "    trusted certs unchanged"; exit 0; fi
    gitlab-ctl reconfigure >/tmp/trusted-certs-reconfigure.log 2>&1 \
      || { echo "FAIL gitlab-ctl reconfigure:" >&2; tail -20 /tmp/trusted-certs-reconfigure.log >&2; exit 1; }
    echo "    trusted certs applied (reconfigured)"'
}

# mint_group_deploy_token NAME SCOPES SECRET...: new token of group deploy token NAME on stdout;
# empty when every SECRET exists in ns $NS and NAME is still active (copies such as per-stage regcred stay valid).
mint_group_deploy_token() {
  local name="$1" scopes="$2" keep=true s res; shift 2
  for s in "$@"; do $KUBECTL -n "$NS" get secret "$s" >/dev/null 2>&1 || keep=false; done
  res="$(gl_rails deploy-token.rb group="$NS" name="$name" scopes="$scopes" keep="$keep")" || return 1
  [ "$(printf '%s' "$res" | json_get kept)" = true ] || printf '%s' "$res" | json_get token
}

if [ "${GITLAB_TRUST_ONLY:-}" = 1 ]; then
  echo "==> GitLab trusted certs (trust step only)"
  $KUBECTL apply -f "$HERE/manifests/gitlab.yaml" >/dev/null
  $KUBECTL -n $GL_NS rollout status deploy/gitlab --timeout=900s >/dev/null
  $KUBECTL -n $GL_NS wait --for=condition=Ready pod -l app=gitlab --timeout=900s >/dev/null
  ensure_trusted_certs
  exit 0
fi

echo "==> Ensuring self-signed TLS cert for $GL_HOST (secret gitlab-tls)"
# The operator's GitLab REST client is https-only; GitLab serves TLS with this
# self-signed cert (CA:TRUE, doubles as the CA). Must exist before the Deployment.
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
# /-/health (liveness) does not imply API/gitlab-shell ready. The GitServer connection
# check (SSH:32222 + API) needs both on first reconcile.
for _ in $(seq 1 90); do
  api="$($KUBECTL -n $GL_NS exec "$POD" -- curl -sk -o /dev/null -w '%{http_code}' https://localhost/api/v4/version 2>/dev/null || echo 000)"
  ssh_up="$($KUBECTL -n $GL_NS exec "$POD" -- bash -c 'timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/22" 2>/dev/null && echo ok' 2>/dev/null || true)"
  case "$api" in 200|401) [ "$ssh_up" = "ok" ] && { echo "    GitLab API ($api) + SSH ready"; break; };; esac
  sleep 5
done

echo "==> GitLab trusted certs (ConfigMap gitlab/trusted-certs, optional)"
ensure_trusted_certs

echo "    Root login: user 'root' / password '$GL_ROOT_PW' (from secret gitlab-root-password)"
echo "    (set on first DB seed; on an existing data PVC reset via:"
echo "     kubectl -n $GL_NS exec $POD -- gitlab-rake \"gitlab:password:reset[root]\")"

echo "==> Tuning instance settings (allow local webhooks; disable Auto DevOps)"
# allow_local_requests…: GitLab blocks webhooks to private IPs by default; the
#   merge_request hook must reach the in-cluster EventListener.
# auto_devops_enabled=false: with the instance default on, every operator-created
#   project (no .gitlab-ci.yml) gets an auto-generated Auto DevOps pipeline (~8 jobs)
#   that sits "stuck" without runners, next to the only status KRCI reads: the "Review
#   Pipeline" external commit status from gitlab-set-status. New projects inherit the
#   instance default; existing ones too, unless explicitly toggled.
gl_rails instance-settings.rb >/dev/null

echo "==> Provisioning the '$NS' group (Codebases live under it, not root's namespace)"
GROUP_JSON="$(gl_rails group.rb path="$NS")"
echo "    group $NS: id=$(printf '%s' "$GROUP_JSON" | json_get id)"

CTX="$CTX" NS="$NS" bash "$HERE/scripts/gitlab-users.sh"

echo "==> Registry credentials: '$NS' group deploy token -> kaniko-docker-config + regcred (ns/$NS)"
# KRCI uses the GitLab Container Registry (:5050).
REG_TOKEN="$(mint_group_deploy_token krci-registry read_registry,write_registry kaniko-docker-config regcred)"
if [ -z "$REG_TOKEN" ]; then
  echo "    deploy token krci-registry active; kaniko-docker-config + regcred kept"
else
  $KUBECTL -n "$NS" create secret docker-registry kaniko-docker-config \
    --docker-server="${GL_HOST}:5050" --docker-username=krci-registry --docker-password="$REG_TOKEN" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  # `regcred`: the image pull secret the cd-pipeline-operator copies into each deploy
  # namespace as the workload imagePullSecret. Without it the Stage reconcile fails
  # ("failed to get regcred secret") and the deploy pipeline's pre-deploy step finds no
  # per-stage configmap. Same creds as kaniko (token has read_registry).
  $KUBECTL -n "$NS" create secret docker-registry regcred \
    --docker-server="${GL_HOST}:5050" --docker-username=krci-registry --docker-password="$REG_TOKEN" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
fi

echo "==> Package registry: '$NS' group deploy token -> ci-nexus (ns/$NS)"
# The edp-tekton maven/npm/python build tasks read secret 'ci-nexus' (keys
# username/password/url); with no Nexus here it points at GitLab's Package Registry.
# Separate group deploy token with package scopes (krci-registry is container-registry only).
PKG_TOKEN="$(mint_group_deploy_token krci-packages read_package_registry,write_package_registry ci-nexus)"
if [ -z "$PKG_TOKEN" ]; then
  echo "    deploy token krci-packages active; ci-nexus kept"
else
  mkdir "$GL_TMP/ci-nexus"
  printf 'krci-packages' >"$GL_TMP/ci-nexus/username"
  printf '%s' "$PKG_TOKEN" >"$GL_TMP/ci-nexus/password"
  printf 'https://%s' "$GL_HOST" >"$GL_TMP/ci-nexus/url"
  apply_secret "$NS" ci-nexus "$GL_TMP/ci-nexus"
  $KUBECTL -n "$NS" label secret ci-nexus \
    app.edp.epam.com/secret-type=nexus app.edp.epam.com/integration-secret=true --overwrite >/dev/null
fi

echo "==> Teaching the kind node's containerd to pull from the GitLab registry"
# Deployed workloads reference gitlab.127.0.0.1.nip.io:5050/<group>/<repo>; containerd
# on the node resolves that host to 127.0.0.1 (nip.io), and the CoreDNS rewrite covers
# pods only, so pulls fail with "dial 127.0.0.1:5050: connection refused". A hosts.toml
# mirrors the registry host to the GitLab service ClusterIP (reachable from the node via
# kube-proxy) with skip_verify for the self-signed cert. config_path is enabled in
# kind/cluster.yaml, so certs.d is read per pull (no containerd restart).
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
echo "    User      : root (Administrator)"
echo "    Password  : $GL_ROOT_PW   (local only — also shown by 'make status')"
echo "    CI user   : krci-ci (KRCI CI/CD; token + SSH key in secret $NS/ci-gitlab)"
echo "    Next: 'make krci' renders the GitServer/EventListener/Ingress from values,"
echo "          then 'make gitlab-integrate' applies the operator CA + task fixes + GitOps repo."
