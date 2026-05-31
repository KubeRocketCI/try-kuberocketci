#!/usr/bin/env bash
# Phase 2: deploy self-hosted GitLab into the kind cluster and register it with
# KubeRocketCI as a GitServer, then wire the webhook path end to end.
#
# Verified mechanism (edp-install 3.13.5 / codebase-operator):
#   - Adding `gitlab` to global.gitProviders renders only the gitlab
#     TriggerBindings/TriggerTemplates. It does NOT create an EventListener.
#   - The EventListener + its Ingress are created PER GitServer by the
#     codebase-operator when `spec.webhookUrl` is empty. For GitServer `gitlab`:
#       EventListener  edp-gitlab
#       Service        el-edp-gitlab            (:8080)
#       Ingress        event-listener-gitlab    host el-gitlab-krci.<wildcard>
#   - The gitlab ClusterInterceptor validates the X-Gitlab-Token against the
#     `secretString` key of the GitServer's secret (nameSshKeySecret). The same
#     value is set as the webhook token in GitLab by the operator.
#   - The operator's GitLab REST client REQUIRES https (the GitServer CRD has only
#     httpsPort, no scheme). So GitLab serves TLS with a self-signed cert and the
#     operator is patched to trust that CA (see "Trusting the ... CA" below).
#
# Two split-horizon DNS rewrites are required (CoreDNS), because both hostnames
# resolve to 127.0.0.1 (localhost) for the browser but must reach in-cluster
# services for pods:
#   - gitlab.<wildcard>          -> gitlab.gitlab.svc           (operator -> GitLab API/clone)
#   - el-gitlab-krci.<wildcard>  -> ingress-nginx controller    (GitLab -> webhook EventListener)
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
GL_NS="gitlab"
WILDCARD="${WILDCARD:-127.0.0.1.nip.io}"
GL_HOST="gitlab.${WILDCARD}"
GS_NAME="gitlab"                       # GitServer name -> EventListener edp-$GS_NAME
EL_HOST=""                             # operator-created webhook ingress host (read live)
KUBECTL="kubectl --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# Ensure a `rewrite name <host> <target>` line exists in the CoreDNS Corefile.
ensure_coredns_rewrite() {
  local host="$1" target="$2"
  if $KUBECTL -n kube-system get configmap coredns -o yaml | grep -q "rewrite name ${host} "; then
    echo "    CoreDNS rewrite for ${host} already present"
    return 0
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
# The codebase-operator's GitLab REST client always uses https://, so GitLab must
# serve TLS. We mint a self-signed cert (also usable as its own CA) and store it
# as a kubernetes.io/tls secret that the Deployment mounts at /etc/gitlab-tls.
# Must exist BEFORE the Deployment is applied (the volume mount requires it).
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

echo "==> Deploying GitLab CE (this is heavy; first boot 3-6 min)"
$KUBECTL apply -f "$HERE/manifests/gitlab.yaml"

echo "==> CoreDNS rewrite for the GitLab host (operator/pods -> GitLab svc)"
$KUBECTL -n kube-system get configmap coredns -o yaml > /tmp/coredns.bak.yaml
COREDNS_CHANGED=0
ensure_coredns_rewrite "$GL_HOST" "gitlab.${GL_NS}.svc.cluster.local"
if [ "$COREDNS_CHANGED" = "1" ]; then $KUBECTL -n kube-system rollout restart deploy/coredns; COREDNS_CHANGED=0; fi
# The EventListener-host rewrite is added later, after the operator creates the
# Ingress (we read its real host rather than assume the naming pattern).

echo "==> Waiting for GitLab to become healthy (polling /-/health)..."
$KUBECTL -n $GL_NS rollout status deploy/gitlab --timeout=900s
$KUBECTL -n $GL_NS wait --for=condition=Ready pod -l app=gitlab --timeout=900s

POD="$($KUBECTL -n $GL_NS get pod -l app=gitlab -o jsonpath='{.items[0].metadata.name}')"
echo "==> GitLab pod: $POD"

echo "==> Waiting for the GitLab API + SSH to actually serve (not just /-/health)"
# /-/health (liveness) returning 200 does NOT mean the REST API and gitlab-shell
# SSH are ready. Everything below — group/PAT/SSH-key/deploy-token via API, and
# especially the GitServer connection check the operator runs (SSH:32222 + API) —
# needs them up, otherwise the operator marks the GitServer failed and the
# EventListener creation is delayed. Gate on both before continuing.
for _ in $(seq 1 90); do
  api="$($KUBECTL -n $GL_NS exec "$POD" -- curl -sk -o /dev/null -w '%{http_code}' https://localhost/api/v4/version 2>/dev/null || echo 000)"
  ssh_up="$($KUBECTL -n $GL_NS exec "$POD" -- bash -c 'timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/22" 2>/dev/null && echo ok' 2>/dev/null || true)"
  # 200 (authed) or 401 (unauthed) both mean the API is serving.
  case "$api" in 200|401) [ "$ssh_up" = "ok" ] && { echo "    GitLab API ($api) + SSH ready"; break; };; esac
  sleep 5
done

echo "    Initial root password:"
$KUBECTL -n $GL_NS exec "$POD" -- cat /etc/gitlab/initial_root_password 2>/dev/null | grep -i password || \
  echo "    (file gone after 24h; reset via: gitlab-rake \"gitlab:password:reset[root]\")"

echo "==> Allowing webhooks to the local network (GitLab blocks them by default)"
$KUBECTL -n $GL_NS exec "$POD" -- gitlab-rails runner '
s = ApplicationSetting.current
s.update!(allow_local_requests_from_web_hooks_and_services: true)' >/dev/null 2>&1 || \
  echo "    (warn) could not set allow_local_requests; set it in Admin -> Network -> Outbound requests"

echo "==> Provisioning the '$NS' group (Codebases live under it, not root's namespace)"
# A real group is tidier than the Administrator personal namespace; the root PAT
# (admin) can create projects in it. Use gitUrlPath: /$NS/<repo> in Codebases.
$KUBECTL -n $GL_NS exec "$POD" -- gitlab-rails runner "
root = User.find_by_username('root')
unless Group.find_by_full_path('$NS')
  Groups::CreateService.new(root, name: '$NS', path: '$NS', visibility_level: Gitlab::VisibilityLevel::PRIVATE).execute
end
g = Group.find_by_full_path('$NS')
puts \"group $NS: id=#{g&.id} persisted=#{g&.persisted?}\"" 2>&1 | grep -iE "group $NS:" || \
  echo "    (warn) could not provision group '$NS'; create it in the GitLab UI"

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

# Webhook shared secret validated by the gitlab ClusterInterceptor (X-Gitlab-Token).
WEBHOOK_SECRET="$(openssl rand -hex 20)"

echo "==> Creating KubeRocketCI git credentials secret (ci-gitlab) in ns/$NS"
# Keys consumed by codebase-operator / edp-tekton (see `kubectl explain gitserver.spec`):
#   token        - GitLab PAT (required)
#   username     - overrides spec.gitUser for API/clone
#   id_rsa       - SSH private key
#   secretString - webhook secret; gitlab ClusterInterceptor validates X-Gitlab-Token
$KUBECTL -n "$NS" create secret generic ci-gitlab \
  --from-literal=token="$TOKEN" \
  --from-literal=username=root \
  --from-literal=secretString="$WEBHOOK_SECRET" \
  --from-file=id_rsa="$TMPKEY" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
rm -f "$TMPKEY" "$TMPKEY.pub"

echo "==> Registry credentials: '$NS' group deploy token + kaniko-docker-config + custom-ca-certificates"
# KubeRocketCI reuses the GitLab Container Registry (:5050). The kaniko build task
# pushes to <host>:5050/$NS/<codebase> using a docker-config secret, and trusts
# the self-signed registry cert via secret custom-ca-certificates (enabled by
# edp-tekton.kaniko.customCert=true in values/edp-install.yaml). Mint a group
# deploy token (read+write registry) via the GitLab API on the pod's localhost,
# revoking any previous 'krci-registry' tokens first (idempotent).
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
else
  echo "    (warn) could not mint registry deploy token; create kaniko-docker-config manually"
fi
$KUBECTL -n $GL_NS get secret gitlab-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/gitlab-reg-ca.crt
$KUBECTL -n "$NS" create secret generic custom-ca-certificates --from-file=ca.crt=/tmp/gitlab-reg-ca.crt \
  --dry-run=client -o yaml | $KUBECTL apply -f -
rm -f /tmp/gitlab-reg-ca.crt

echo "==> Trusting the GitLab self-signed CA in codebase-operator"
# The operator's GitLab REST client VERIFIES TLS (skipWebhookSSLVerification only
# covers webhooks, not the API client), so it must trust our self-signed CA or
# project/webhook creation fails with x509 "unknown authority". We publish the
# cert as a ConfigMap and mount it into /etc/ssl/certs (Go scans that dir IN
# ADDITION to the system bundle, so public CAs for template fetches still work).
# This additive volume/mount survives `make krci`: Helm's 3-way merge leaves
# fields it doesn't own, so the patch is re-applied idempotently here anyway.
$KUBECTL -n "$GL_NS" get secret gitlab-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/gitlab-ca.crt
$KUBECTL -n "$NS" create configmap gitlab-ca --from-file=gitlab-ca.crt=/tmp/gitlab-ca.crt \
  --dry-run=client -o yaml | $KUBECTL apply -f -
rm -f /tmp/gitlab-ca.crt
OP_CN="$($KUBECTL -n "$NS" get deploy codebase-operator -o jsonpath='{.spec.template.spec.containers[0].name}')"
$KUBECTL -n "$NS" patch deploy codebase-operator --type strategic -p "{\"spec\":{\"template\":{\"spec\":{\"volumes\":[{\"name\":\"gitlab-ca\",\"configMap\":{\"name\":\"gitlab-ca\"}}],\"containers\":[{\"name\":\"${OP_CN}\",\"volumeMounts\":[{\"name\":\"gitlab-ca\",\"mountPath\":\"/etc/ssl/certs/gitlab-ca.crt\",\"subPath\":\"gitlab-ca.crt\",\"readOnly\":true}]}]}}}}"
$KUBECTL -n "$NS" rollout status deploy/codebase-operator --timeout=120s

echo "==> Registering the GitServer CR ($GS_NAME) — webhookUrl left empty so the"
echo "    codebase-operator creates EventListener edp-$GS_NAME + its Ingress."
cat <<EOF | $KUBECTL apply -f -
apiVersion: v2.edp.epam.com/v1
kind: GitServer
metadata:
  name: $GS_NAME
  namespace: $NS
spec:
  gitProvider: gitlab
  gitHost: $GL_HOST
  gitUser: git
  httpsPort: 443
  sshPort: 32222
  nameSshKeySecret: ci-gitlab
  skipWebhookSSLVerification: true
EOF

echo "==> Waiting for the operator to create + ready EventListener edp-$GS_NAME"
# The operator creates the EL only AFTER the GitServer connects (SSH check), which
# can lag a few seconds behind GitServer creation. Poll for the resource to EXIST
# first (kubectl wait errors out on a missing named resource), then wait Ready.
for _ in $(seq 1 60); do
  $KUBECTL -n "$NS" get eventlistener edp-$GS_NAME >/dev/null 2>&1 && break
  sleep 5
done
$KUBECTL -n "$NS" wait --for=condition=Ready eventlistener/edp-$GS_NAME --timeout=180s 2>/dev/null || \
  $KUBECTL -n "$NS" rollout status deploy/el-edp-$GS_NAME --timeout=180s

echo "==> Reading the operator-created webhook Ingress host + adding its CoreDNS rewrite"
# Read the real host instead of assuming the naming pattern, then point it (from
# inside the cluster) at the ingress-nginx controller so GitLab can POST webhooks.
for i in $(seq 1 30); do
  EL_HOST="$($KUBECTL -n "$NS" get ingress -l app.kubernetes.io/managed-by=codebase-operator \
    -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}' 2>/dev/null | grep -m1 "el-${GS_NAME}-" || true)"
  [ -z "$EL_HOST" ] && EL_HOST="$($KUBECTL -n "$NS" get ingress event-listener-${GS_NAME} -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
  [ -n "$EL_HOST" ] && break
  sleep 2
done
if [ -n "$EL_HOST" ]; then
  ensure_coredns_rewrite "$EL_HOST" "ingress-nginx-controller.ingress-nginx.svc.cluster.local"
  if [ "$COREDNS_CHANGED" = "1" ]; then $KUBECTL -n kube-system rollout restart deploy/coredns; fi
else
  echo "    (warn) could not find the EventListener ingress host; check 'kubectl -n $NS get ingress'"
  EL_HOST="(unknown)"
fi

echo "==> Fixing the gitlab-set-status task (host parse + self-signed TLS)"
# The stock edp-tekton task mis-parses our ssh://…:32222/… git URL (-> host "ssh")
# and verifies TLS against a self-signed cert, so every pipeline aborts at the
# 'report-pipeline-start-to-gitlab' step. Patch its script with the corrected one.
# (Survives `make krci`: helm 3-way merge only resets fields the chart changes.)
if $KUBECTL -n "$NS" get task gitlab-set-status >/dev/null 2>&1; then
  PATCH="$(python3 -c "import json;print(json.dumps([{'op':'replace','path':'/spec/steps/0/script','value':open('$HERE/scripts/gitlab-set-status.py').read()}]))")"
  $KUBECTL -n "$NS" patch task gitlab-set-status --type=json -p "$PATCH"
else
  echo "    (skip) gitlab-set-status task not found — run 'make krci' first"
fi

echo "==> Onboarding the KubeRocketCI GitOps repository ($NS/krci-gitops)"
# A GitOps repo (system/helm/gitops Codebase) must exist before Deployments/CD
# pipelines. Provisioned declaratively — same pattern the Portal's "Add GitOps
# repository" produces. Depends on the gitlab GitServer + '$NS' group above.
$KUBECTL apply -f "$HERE/manifests/krci-gitops.yaml"

echo ""
echo "==> Done."
echo "    GitLab UI : https://$GL_HOST   (user: root, password above; self-signed cert)"
echo "    GitServer : $GS_NAME  (ns/$NS)  -> kubectl -n $NS get gitservers"
echo "    Webhook   : EventListener edp-$GS_NAME, ingress host $EL_HOST"
echo "    Group     : $NS  (use gitUrlPath: /$NS/<repo> in Codebases)
    GitOps    : $NS/krci-gitops  (system codebase) -> kubectl -n $NS get codebase
    Registry  : ${GL_HOST}:5050  (KRCI pushes to /$NS/<codebase>; creds in secret kaniko-docker-config)
    Next      : create a Codebase using GitServer '$GS_NAME'; the operator"
echo "                creates the project webhook. Push/MR -> PipelineRun in ns/$NS."
