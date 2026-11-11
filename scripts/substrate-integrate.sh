#!/usr/bin/env bash
# Optional post-KRCI Substrate integration, not part of `make testbed`: the landing zone krci-agents
# for agent workloads and krci-agent-dispatcher on it. Requires `make substrate` and `make krci`
# (group krci, krci/gitlab-ca, cert-manager, ingress-nginx). Re-run after `make substrate`.
# No test project here: the project hook is `make substrate-hook`.
#   * egress gateway upstream TLS: image roots + the CA in SUBSTRATE_EGRESS_CA (<ns>/<configmap>, key
#     gitlab-ca.crt; default krci/gitlab-ca; empty: skipped). Upstream v1.0.0 has no setting for it.
#     manifests/substrate-egress-upstream-ca.yaml, server-side apply under field manager krci-testbed.
#   * namespace + atespace krci-agents, WorkerPool krci-agents/workers (ateworker-gvisor at the
#     installed Substrate version): manifests/substrate-landing.yaml.
#   * credential provider namespace policy krci-agents -> [krci-agents]:
#     manifests/substrate-namespace-policy.yaml.
#   * GitLab user krci-agent (KRCI Agent): Developer on group krci (clone, push to unprotected
#     branches, merge requests, notes, labels). Token krci-agent: api + write_repository, 30 days;
#     replaced on every run.
#   * secret krci-agents/gitlab: token; basic = base64("oauth2:<token>") (Authorization: Basic
#     value for git over HTTPS).
#   * krci-agent-dispatcher AGENT_DISPATCHER_VERSION from Helm repo AGENT_DISPATCHER_REPO,
#     values/agent-dispatcher.yaml, agentImage KRCI_AGENT_IMAGE
#     (<repo>[:<tag>]@sha256:<digest>). Before the release:
#     - namespace label ate.dev/api-access=true (NetworkPolicy ate-system/ate-api-server);
#     - atespace access policy: role editor for ServiceAccount krci-agents/krci-agent-dispatcher,
#       added to the existing bindings;
#     - secret krci-agents/hook (key token, 40 hex), created once;
#     - configmap krci-agents/gitlab-ca (key ca.crt) from krci/gitlab-ca;
#     - testbed CA (manifests/agent-dispatcher-ca.yaml), CoreDNS rewrite of the dispatcher host to
#       ingress-nginx, GitLab trust of the CA (gitlab/trusted-certs key krci-agents-ca.crt,
#       GITLAB_TRUST_ONLY=1 scripts/gitlab-up.sh).
#     The dispatcher reads the GitLab token from the mounted secret on each use: no restart after the
#     token is replaced.
#   * secret krci-agents/anthropic, key api-key = the Anthropic API key (sk-ant-..., nothing else):
#     created by you with kubectl, never by this script or from a file in the repo (upstream
#     docs/guides/egress-credential-injection.md). Checked last; when absent, the command is
#     printed. The same command rotates it; the credential provider reads the Secret on each request.
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
SUBSTRATE_VERSION="${SUBSTRATE_VERSION:?SUBSTRATE_VERSION is required}"
AGENTS_NS=krci-agents
SUBSTRATE_EGRESS_CA="${SUBSTRATE_EGRESS_CA-krci/gitlab-ca}"
AGENT_DISPATCHER_VERSION="${AGENT_DISPATCHER_VERSION:?AGENT_DISPATCHER_VERSION is required}"
AGENT_DISPATCHER_REPO="${AGENT_DISPATCHER_REPO:?AGENT_DISPATCHER_REPO is required}"
KRCI_AGENT_IMAGE="${KRCI_AGENT_IMAGE:?KRCI_AGENT_IMAGE is required: <repo>[:<tag>]@sha256:<digest>}"
[[ "$KRCI_AGENT_IMAGE" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] || {
  echo "FAIL KRCI_AGENT_IMAGE=$KRCI_AGENT_IMAGE is not pinned by digest: use <repo>[:<tag>]@sha256:<digest>" >&2
  exit 1
}
WILDCARD="${WILDCARD:-127.0.0.1.nip.io}"
DISPATCHER=krci-agent-dispatcher
DISPATCHER_HOST="agent-dispatcher.${WILDCARD}"
TRUST_KEY=krci-agents-ca.crt
FIELD_MANAGER=krci-testbed
KUBECTL="kubectl --context $CTX"
KUBECTL_ATE="kubectl ate --context $CTX"
HELM="helm --kube-context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PATH="$HERE/.cache/substrate/$SUBSTRATE_VERSION/bin:$PATH"
. "$HERE/scripts/lib/gitlab.sh"
. "$HERE/scripts/lib/coredns.sh"

egress_upstream_ca() {
  local src="$SUBSTRATE_EGRESS_CA" dir="$GL_TMP/egress-ca" img hash
  if [ -z "$src" ]; then echo "    (skip) SUBSTRATE_EGRESS_CA is empty"; return 0; fi
  img="$($KUBECTL -n ate-system get deploy atenet-egress \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="envoy")].image}' 2>/dev/null || true)"
  [ -n "$img" ] || { echo "FAIL ate-system/atenet-egress not found: run make substrate first" >&2; exit 1; }
  mkdir "$dir"
  $KUBECTL -n "${src%/*}" get configmap "${src#*/}" -o jsonpath='{.data.gitlab-ca\.crt}' >"$dir/ca.crt" 2>/dev/null || true
  grep -q 'BEGIN CERTIFICATE' "$dir/ca.crt" || { echo "FAIL no CA (key gitlab-ca.crt) in configmap $src" >&2; exit 1; }
  hash="$(shasum -a 256 "$dir/ca.crt" | cut -c1-64)"
  $KUBECTL -n ate-system create configmap egress-upstream-ca --from-file=ca.crt="$dir/ca.crt" --dry-run=client -o yaml \
    | $KUBECTL apply --server-side --field-manager="$FIELD_MANAGER" -f - >/dev/null
  sed -e "s|@IMAGE@|$img|" -e "s|@HASH@|$hash|" "$HERE/manifests/substrate-egress-upstream-ca.yaml" \
    | $KUBECTL apply --server-side --field-manager="$FIELD_MANAGER" -f - >/dev/null
  $KUBECTL -n ate-system rollout status deploy/atenet-egress --timeout=180s >/dev/null
  echo "    egress gateway trusts $src (sha256 ${hash:0:12})"
}

landing_zone() {
  local atelet worker hash policy="$HERE/manifests/substrate-namespace-policy.yaml"
  command -v kubectl-ate >/dev/null || { echo "FAIL kubectl-ate $SUBSTRATE_VERSION not found: run make substrate first" >&2; exit 1; }
  atelet="$($KUBECTL -n ate-system get daemonset atelet \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="atelet")].image}' 2>/dev/null || true)"
  [ -n "$atelet" ] || { echo "FAIL ate-system/atelet not found: run make substrate first" >&2; exit 1; }
  atelet="${atelet%@*}"
  worker="${atelet%/*}/ateworker-gvisor:${atelet##*:}"
  sed -e "s|@WORKER_IMAGE@|$worker|" "$HERE/manifests/substrate-landing.yaml" \
    | $KUBECTL apply --server-side --field-manager="$FIELD_MANAGER" -f - >/dev/null
  $KUBECTL -n "$AGENTS_NS" wait workerpool/workers --for=jsonpath='{.status.readyReplicas}'=1 --timeout=300s >/dev/null
  echo "    namespace $AGENTS_NS, WorkerPool workers ready ($worker)"
  if $KUBECTL_ATE get atespace "$AGENTS_NS" >/dev/null 2>&1; then
    echo "    atespace $AGENTS_NS present"
  else
    $KUBECTL_ATE create atespace "$AGENTS_NS" >/dev/null 2>&1
    echo "    atespace $AGENTS_NS created"
  fi
  hash="$(shasum -a 256 "$policy" | cut -c1-64)"
  sed -e "s|@POLICY_HASH@|$hash|" "$policy" \
    | $KUBECTL apply --server-side --force-conflicts --field-manager="$FIELD_MANAGER" -f - >/dev/null
  $KUBECTL -n ate-system rollout status deployment/k8s-credential-provider --timeout=120s >/dev/null
  echo "    namespace policy $AGENTS_NS -> [$AGENTS_NS] (sha256 ${hash:0:12})"
}

# kubectl ate get access-policy: exit 0 and empty stdout when the atespace has no policy.
access_policy_grant() {
  local member="user:system:serviceaccount:$AGENTS_NS:$DISPATCHER" cur err="$GL_TMP/access-policy.err"
  cur="$($KUBECTL_ATE get access-policy -a "$AGENTS_NS" -o json 2>"$err")" \
    || { echo "FAIL access policy read: $(grep -v '^Warning' "$err")" >&2; exit 1; }
  if [ -z "$cur" ]; then
    printf 'bindings:\n- role: editor\n  members:\n  - %s\n' "$member" \
      | $KUBECTL_ATE create access-policy -a "$AGENTS_NS" -f - >/dev/null 2>"$err" \
      || { echo "FAIL access policy create: $(grep -v '^Warning' "$err")" >&2; exit 1; }
    echo "    access policy: created, editor $member"
  elif jq -e --arg m "$member" 'any(.bindings[]?; .role == "editor" and ((.members // []) | index($m)))' \
    <<<"$cur" >/dev/null; then
    echo "    access policy: editor $member present"
  else
    jq --arg m "$member" 'del(.metadata.atespace) | .bindings = ((.bindings // []) + [{role: "editor", members: [$m]}])' \
      <<<"$cur" | $KUBECTL_ATE update access-policy -a "$AGENTS_NS" -f - >/dev/null 2>"$err" \
      || { echo "FAIL access policy update: $(grep -v '^Warning' "$err")" >&2; exit 1; }
    echo "    access policy: editor $member added"
  fi
}

dispatcher_tls() {
  local dir="$1"
  $KUBECTL apply --server-side --field-manager="$FIELD_MANAGER" -f "$HERE/manifests/agent-dispatcher-ca.yaml" >/dev/null
  $KUBECTL -n "$AGENTS_NS" wait certificate/krci-agents-ca --for=condition=Ready --timeout=120s >/dev/null
  $KUBECTL -n "$AGENTS_NS" get secret krci-agents-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"$dir/testbed-ca.crt"
  grep -q 'BEGIN CERTIFICATE' "$dir/testbed-ca.crt" || { echo "FAIL no ca.crt in secret $AGENTS_NS/krci-agents-ca" >&2; exit 1; }
  echo "    testbed CA: Issuer $AGENTS_NS/krci-agents-ca ready"

  COREDNS_CHANGED=0
  ensure_coredns_rewrite "$DISPATCHER_HOST" ingress-nginx-controller.ingress-nginx.svc.cluster.local
  if [ "$COREDNS_CHANGED" = 1 ]; then
    $KUBECTL -n kube-system rollout restart deploy/coredns >/dev/null
    $KUBECTL -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null
  fi

  $KUBECTL -n gitlab create configmap trusted-certs --from-file="$TRUST_KEY=$dir/testbed-ca.crt" --dry-run=client -o yaml \
    | $KUBECTL apply --server-side --field-manager="$FIELD_MANAGER" -f - >/dev/null
  CTX="$CTX" NS="$NS" WILDCARD="$WILDCARD" GITLAB_TRUST_ONLY=1 bash "$HERE/scripts/gitlab-up.sh"
}

agent_dispatcher() {
  local dir="$GL_TMP/dispatcher"
  mkdir -p "$dir/hook"
  $KUBECTL -n "$NS" get configmap gitlab-ca -o jsonpath='{.data.gitlab-ca\.crt}' >"$dir/gitlab-ca.crt" 2>/dev/null || true
  grep -q 'BEGIN CERTIFICATE' "$dir/gitlab-ca.crt" || { echo "FAIL no CA (key gitlab-ca.crt) in configmap $NS/gitlab-ca: run make krci first" >&2; exit 1; }
  $KUBECTL get crd certificates.cert-manager.io >/dev/null 2>&1 || { echo "FAIL cert-manager not found: run make krci first" >&2; exit 1; }

  $KUBECTL label namespace "$AGENTS_NS" ate.dev/api-access=true --overwrite >/dev/null
  echo "    namespace $AGENTS_NS: label ate.dev/api-access=true"
  access_policy_grant

  if $KUBECTL -n "$AGENTS_NS" get secret hook >/dev/null 2>&1; then
    echo "    secret $AGENTS_NS/hook present"
  else
    openssl rand -hex 20 | tr -d '\n' >"$dir/hook/token"
    apply_secret "$AGENTS_NS" hook "$dir/hook"
  fi
  $KUBECTL -n "$AGENTS_NS" create configmap gitlab-ca --from-file=ca.crt="$dir/gitlab-ca.crt" --dry-run=client -o yaml \
    | $KUBECTL apply --server-side --field-manager="$FIELD_MANAGER" -f - >/dev/null
  echo "    configmap $AGENTS_NS/gitlab-ca from $NS/gitlab-ca"

  dispatcher_tls "$dir"

  $HELM upgrade --install "$DISPATCHER" "$AGENT_DISPATCHER_REPO/$DISPATCHER" --version "$AGENT_DISPATCHER_VERSION" \
    -n "$AGENTS_NS" -f "$HERE/values/agent-dispatcher.yaml" \
    --set image.tag="$AGENT_DISPATCHER_VERSION" --set agentImage="$KRCI_AGENT_IMAGE" --set ingress.host="$DISPATCHER_HOST" \
    --wait --timeout 5m >/dev/null
  echo "    $DISPATCHER $AGENT_DISPATCHER_VERSION ready: https://$DISPATCHER_HOST/hook (agent image $KRCI_AGENT_IMAGE)"
}

echo "==> Egress gateway upstream CA"
egress_upstream_ca

echo "==> Landing zone $AGENTS_NS"
landing_zone

echo "==> KRCI Agent (krci-agent): Developer on group $NS -> secret $AGENTS_NS/gitlab"
DIR="$GL_TMP/gitlab"
mkdir "$DIR"
onboard_gitlab_user username=krci-agent name="KRCI Agent" avatar=@"$HERE/assets/krci-agent-avatar.png" \
  group="$NS" access=developer token_name=krci-agent scopes=api,write_repository expires_days=30 >"$DIR/token"
printf 'oauth2:%s' "$(cat "$DIR/token")" | base64 | tr -d '\n' >"$DIR/basic"
apply_secret "$AGENTS_NS" gitlab "$DIR"

echo "==> krci-agent-dispatcher $AGENT_DISPATCHER_VERSION in $AGENTS_NS"
agent_dispatcher

echo "==> Anthropic API key (secret $AGENTS_NS/anthropic, key api-key)"
if $KUBECTL -n "$AGENTS_NS" get secret anthropic >/dev/null 2>&1; then
  echo "    present"
else
  cat <<EOF
    (todo) missing: agents cannot call Claude until it exists. Put your key in place of
    <ANTHROPIC_API_KEY> and run (the same command rotates it):

      $KUBECTL -n $AGENTS_NS create secret generic anthropic --from-literal=api-key=<ANTHROPIC_API_KEY> \\
        --dry-run=client -o yaml | $KUBECTL apply -f -
EOF
fi
