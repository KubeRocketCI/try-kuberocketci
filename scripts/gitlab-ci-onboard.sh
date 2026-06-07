#!/usr/bin/env bash
# Onboard a Java/Maven application that runs its CI in GitLab CI instead of Tekton.
# Pairs with scripts/gitlab-runner.sh (the runner) and scripts/e2e-gitlabci.sh (the e2e).
#
# What it does (idempotent), all host-side over the GitLab ingress (self-signed, -k):
#   1. mirror the upstream KubeRocketCI component gitlab.com/kuberocketci/ci-java17-mvn
#      into THIS GitLab as kuberocketci/ci-java17-mvn @0.1.1 — GitLab CI/CD components
#      only resolve on the same instance ($CI_SERVER_FQDN). The mirror carries ONE local
#      deviation: the buildkit-build job pushes to the in-cluster GitLab registry
#      ($CI_REGISTRY_IMAGE, job-token auth, registry.insecure) instead of Docker Hub.
#   2. seed the app repo krci/java-gitlabci-app from the same sample sources, minus its
#      own .gitlab-ci.yml (so the codebase-operator injects ours) and minus templates/
#      (the app includes the mirrored component instead).
#   3. set krci-group CI/CD variables the pipeline needs (SONAR_HOST_URL/TOKEN,
#      GITLAB_ACCESS_TOKEN).
#   4. apply the gitlab-ci-java-maven ConfigMap + the Codebase (ciTool=gitlab) and wait
#      for the operator to push .gitlab-ci.yml.
set -euo pipefail

CTX="${CTX:-kind-krci}"
NS="${NS:-krci}"
GL_NS="gitlab"
WILDCARD="${WILDCARD:-127.0.0.1.nip.io}"
GL_HOST="gitlab.${WILDCARD}"
KUBECTL="kubectl --context $CTX"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

COMPONENT_PATH="kuberocketci/ci-java17-mvn"
COMPONENT_REF="0.1.1"
UPSTREAM="https://gitlab.com/kuberocketci/ci-java17-mvn.git"
APP="java-gitlabci-app"
APP_GROUP="krci"

PAT="$($KUBECTL -n $NS get secret ci-gitlab -o jsonpath='{.data.token}' | base64 -d)"
API="https://${GL_HOST}/api/v4"
# We seed repos with the GitLab commits API (gitaly OperationService) rather than a git
# push — simplest from the host (no working tree / push auth), and the same approach the
# e2e scripts use. The operator still does the real git ops (clone + inject .gitlab-ci.yml).
GITC="git -c http.sslVerify=false -c commit.gpgsign=false"

# Host-side GitLab REST (via the ingress, self-signed). api METHOD PATH [JSON]
api() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sk -X "$m" -H "PRIVATE-TOKEN: $PAT" -H 'Content-Type: application/json' -d "$b" "$API/$p"
  else curl -sk -X "$m" -H "PRIVATE-TOKEN: $PAT" "$API/$p"; fi; }
enc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
jqid() { python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print(d.get("id","") if isinstance(d,dict) else "")'; }

group_id() { api GET "groups/$(enc "$1")" | jqid; }
ensure_group() { local path="$1" vis="$2"
  local id; id="$(group_id "$path")"
  [ -n "$id" ] && { echo "$id"; return; }
  api POST "groups" "$(printf '{"name":"%s","path":"%s","visibility":"%s"}' "$path" "$path" "$vis")" | jqid; }
ensure_project() { local group_id="$1" name="$2" vis="$3" path="$4"
  local id; id="$(api GET "projects/$(enc "$path")" | jqid)"
  [ -n "$id" ] && { echo "$id"; return; }
  api POST "projects" "$(printf '{"name":"%s","namespace_id":%s,"visibility":"%s","initialize_with_readme":false}' "$name" "$group_id" "$vis")" | jqid; }
set_group_var() { local gid="$1" key="$2" val="$3" type="${4:-env_var}"
  api DELETE "groups/$gid/variables/$key" >/dev/null 2>&1 || true
  # curl --data-urlencode handles multi-line values (e.g. the CA PEM) cleanly.
  curl -sk -X POST -H "PRIVATE-TOKEN: $PAT" \
    --data-urlencode "key=$key" --data-urlencode "value=$val" \
    --data-urlencode "variable_type=$type" \
    --data-urlencode "protected=false" --data-urlencode "masked=false" \
    "$API/groups/$gid/variables" >/dev/null; }

# Populate a project's main branch from a directory via the commits API (create-or-update
# per file, base64 content, preserve the executable bit e.g. mvnw). Idempotent.
# seed_repo PROJECT_PATH SRC_DIR COMMIT_MSG
seed_repo() {
  PROJECT_PATH="$1" SRC_DIR="$2" MSG="$3" API_BASE="$API" TOKEN="$PAT" python3 - <<'PY'
import os,sys,json,base64,ssl,urllib.request,urllib.parse
api=os.environ["API_BASE"]; tok=os.environ["TOKEN"]
proj=urllib.parse.quote(os.environ["PROJECT_PATH"],safe=""); src=os.environ["SRC_DIR"]; msg=os.environ["MSG"]
ctx=ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
def req(method,path,body=None):
    data=json.dumps(body).encode() if body is not None else None
    r=urllib.request.Request(f"{api}/{path}",data=data,method=method,
        headers={"PRIVATE-TOKEN":tok,"Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(r,context=ctx) as resp: return resp.status, resp.read()
    except urllib.error.HTTPError as e: return e.code, e.read()
existing=set(); page=1
while True:
    st,body=req("GET",f"projects/{proj}/repository/tree?recursive=true&ref=main&per_page=100&page={page}")
    if st!=200: break
    items=json.loads(body)
    if not items: break
    existing|={it["path"] for it in items if it["type"]=="blob"}
    page+=1
actions=[]
for root,dirs,files in os.walk(src):
    dirs[:]=[d for d in dirs if d!=".git"]
    for f in files:
        full=os.path.join(root,f); rel=os.path.relpath(full,src)
        with open(full,"rb") as fh: content=fh.read()
        act={"action":"update" if rel in existing else "create","file_path":rel,
             "content":base64.b64encode(content).decode(),"encoding":"base64"}
        if os.access(full,os.X_OK): act["execute_filemode"]=True
        actions.append(act)
if not actions: print("    (no files to seed)"); sys.exit(0)
st,body=req("POST",f"projects/{proj}/repository/commits",
    {"branch":"main","commit_message":msg,"actions":actions})
if st not in (200,201): print(f"    seed FAILED (HTTP {st}): {body[:300]}"); sys.exit(1)
print(f"    seeded {len(actions)} files -> {os.environ['PROJECT_PATH']}")
PY
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── 1. mirror the component (public, so the app's CI job token can include it) ──
echo "==> Mirroring $COMPONENT_PATH @$COMPONENT_REF into the local GitLab (with local-registry patch)"
KGID="$(ensure_group kuberocketci public)"; [ -n "$KGID" ] || { echo "!! could not ensure kuberocketci group" >&2; exit 1; }
ensure_project "$KGID" ci-java17-mvn public "$COMPONENT_PATH" >/dev/null
$GITC clone --quiet --depth 1 --branch "$COMPONENT_REF" "$UPSTREAM" "$TMP/comp"
rm -rf "$TMP/comp/.git"
# Local deviations to the mirrored component (only the two the local env genuinely
# needs — see docs/gitlab-ci.md). git-tag stays upstream (git push works under Rosetta):
#   build.yml/review.yml  buildkit jobs -> push to the in-cluster GitLab registry over
#                         the job token, and build NATIVE arm64 (drop --platform amd64,
#                         which would need emulation — and we must NOT install QEMU,
#                         it replaces Rosetta and crashes GitLab's gitaly).
#   common.yml .buildkit-base -> SSL_CERT_FILE bundle so buildkit trusts the self-signed
#                         registry + its jwt/auth token host.
( cd "$TMP/comp"; python3 - <<'PY'
import sys,re
ok=True
def patch(path, fn):
    global ok
    s=open(path).read(); ns=fn(s)
    if ns is None: ok=False; print("    !! patch failed:",path); return
    open(path,"w").write(ns)

def strip_amd64(s):
    # native arm64 build (no emulation) — remove the forced --platform line
    return re.sub(r'[ \t]*--opt platform=linux/amd64 \\\n', '', s)

def build_yml(s):
    a_old=r'\"https://index.docker.io/v1/\":{\"username\":\"${DOCKERHUB_USERNAME}\",\"password\":\"${DOCKERHUB_PASSWORD}\"}'
    a_new=r'\"$CI_REGISTRY\":{\"username\":\"$CI_REGISTRY_USER\",\"password\":\"$CI_REGISTRY_PASSWORD\"}'
    b_old='name=${IMAGE_REGISTRY}/${CODEBASE_NAME}:${IMAGE_TAG},push=true'
    b_new='name=$CI_REGISTRY_IMAGE:${IMAGE_TAG},push=true'
    if a_old not in s or b_old not in s: return None
    s=s.replace(a_old,a_new).replace(b_old,b_new)
    s=strip_amd64(s)
    return s if 'platform=linux/amd64' not in s else None

def review_yml(s):
    s=strip_amd64(s)
    return s if 'platform=linux/amd64' not in s else None

def common_yml(s):
    if ".buildkit-base:" not in s: return None
    return s.split(".buildkit-base:")[0]+BUILDKIT_BASE

BUILDKIT_BASE=r'''.buildkit-base:
  image:
    name: moby/buildkit:rootless
    entrypoint: [""]
  before_script:
    - mkdir -p ~/.docker
    # Local deviation: trust the in-cluster GitLab self-signed cert (registry :5050 AND
    # the jwt/auth token host :443). Go honours SSL_CERT_FILE, so build a bundle of the
    # system CAs + the GitLab CA (group file var GITLAB_REGISTRY_CA) for buildkitd.
    - |
      if [ -n "${GITLAB_REGISTRY_CA:-}" ]; then
        cat /etc/ssl/certs/ca-certificates.crt "$GITLAB_REGISTRY_CA" > /tmp/ca-bundle.crt
        export SSL_CERT_FILE=/tmp/ca-bundle.crt
      fi
  variables:
    BUILDKITD_FLAGS: --oci-worker-no-process-sandbox
'''

patch("templates/build.yml", build_yml)
patch("templates/review.yml", review_yml)
patch("templates/common.yml", common_yml)
print("    component patched: buildkit -> local registry (native arm64) + CA bundle" if ok else "    component patch INCOMPLETE")
sys.exit(0 if ok else 1)
PY
)
seed_repo "$COMPONENT_PATH" "$TMP/comp" "Mirror of kuberocketci/ci-java17-mvn @$COMPONENT_REF (local registry patch)"
# (re)create the version tag the ConfigMap pins (component:@0.1.1)
api DELETE "projects/$(enc "$COMPONENT_PATH")/repository/tags/$COMPONENT_REF" >/dev/null 2>&1 || true
api POST "projects/$(enc "$COMPONENT_PATH")/repository/tags?tag_name=${COMPONENT_REF}&ref=main" >/dev/null
echo "    component mirrored: https://${GL_HOST}/${COMPONENT_PATH} (tag $COMPONENT_REF)"

# ── 2. seed the app repo from the sample sources (minus .gitlab-ci.yml + templates/) ──
echo "==> Seeding the application repo $APP_GROUP/$APP from the sample sources"
AGID="$(group_id $APP_GROUP)"; [ -n "$AGID" ] || { echo "!! group $APP_GROUP missing (run make gitlab-up?)" >&2; exit 1; }
ensure_project "$AGID" "$APP" private "$APP_GROUP/$APP" >/dev/null
$GITC clone --quiet --depth 1 --branch "$COMPONENT_REF" "$UPSTREAM" "$TMP/app"
rm -rf "$TMP/app/.git"
rm -f  "$TMP/app/.gitlab-ci.yml"   # so the codebase-operator injects ours
rm -rf "$TMP/app/templates"        # the app includes the mirrored component, not local templates
# Local deviation: the sample Dockerfile bases on eclipse-temurin:17-jre-alpine, which is
# amd64-only. We build NATIVE arm64 (no QEMU), so swap to the multi-arch eclipse-temurin:
# 17-jre (Debian) base — also drops the brittle apk version pins. hadolint-clean.
cat > "$TMP/app/Dockerfile" <<'DOCKERFILE'
FROM eclipse-temurin:17-jre

ENV JAVA_OPTS="-Xmx512m -Xms256m -Djava.security.egd=file:/dev/./urandom" \
    SPRING_PROFILES_ACTIVE=prod

# system account (no fixed UID/GID — the Debian base already uses 1000)
RUN useradd --system --create-home --home-dir /home/spring spring

WORKDIR /app

COPY target/*.jar /app/app.jar

RUN chown -R spring /app

USER spring

EXPOSE 8080

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar /app/app.jar"]
DOCKERFILE
echo "    Dockerfile -> multi-arch eclipse-temurin:17-jre (native arm64 build)"
seed_repo "$APP_GROUP/$APP" "$TMP/app" "KubeRocketCI GitLab CI sample app (java17-mvn)"
echo "    app seeded: https://${GL_HOST}/${APP_GROUP}/${APP}"

# ── 3. group CI/CD variables the pipeline needs ──
echo "==> Setting $APP_GROUP-group CI/CD variables (sonar + access token + registry CA)"
SONAR_TOKEN="$($KUBECTL -n $NS get secret ci-sonarqube -o jsonpath='{.data.token}' | base64 -d)"
GL_CA="$($KUBECTL -n $GL_NS get secret gitlab-tls -o jsonpath='{.data.tls\.crt}' | base64 -d)"
set_group_var "$AGID" SONAR_HOST_URL "http://sonar.sonar:9000"
set_group_var "$AGID" SONAR_TOKEN "$SONAR_TOKEN"
set_group_var "$AGID" GITLAB_ACCESS_TOKEN "$PAT"
# FILE var: GitLab self-signed CA, so buildkit can trust the registry + jwt/auth host.
set_group_var "$AGID" GITLAB_REGISTRY_CA "$GL_CA" file
echo "    SONAR_HOST_URL, SONAR_TOKEN, GITLAB_ACCESS_TOKEN, GITLAB_REGISTRY_CA(file) set on group $APP_GROUP"

# ── 4. apply the template ConfigMap + the Codebase; the OPERATOR injects .gitlab-ci.yml ──
# With gitaly healthy (Rosetta, no QEMU), the operator's normal ciTool=gitlab flow works:
# it clones the seeded repo, injects .gitlab-ci.yml from this ConfigMap, and pushes it —
# the faithful KubeRocketCI behaviour. (disablePutDeployTemplates keeps the sample's chart.)
echo "==> Applying the gitlab-ci-java-maven ConfigMap + the Codebase (ciTool=gitlab)"
$KUBECTL apply -f "$HERE/manifests/gitlab-ci-java-maven-configmap.yaml"
$KUBECTL apply -f "$HERE/manifests/sample-gitlabci-codebase.yaml"

echo "==> Waiting for the Codebase to be provisioned + .gitlab-ci.yml injected by the operator"
st=""
for _ in $(seq 1 60); do
  st="$($KUBECTL -n $NS get codebase $APP -o jsonpath='{.status.status}' 2>/dev/null || true)"
  [ "$st" = created ] && break
  [ "$st" = failed ] && { echo "!! codebase reconcile failed: $($KUBECTL -n $NS get codebase $APP -o jsonpath='{.status.detailedMessage}')" >&2; exit 1; }
  sleep 5
done
[ "$st" = created ] || { echo "!! codebase not provisioned (status='$st')" >&2; exit 1; }
HAS_CI=""
for _ in $(seq 1 24); do
  api GET "projects/$(enc "$APP_GROUP/$APP")/repository/files/$(enc .gitlab-ci.yml)?ref=main" | grep -q '"file_name"' && { HAS_CI=1; break; }
  sleep 5
done

echo ""
echo "==> gitlab-ci-onboard done."
echo "    Component : https://${GL_HOST}/${COMPONENT_PATH}   (tag $COMPONENT_REF, native-arm64 + local-registry patch)"
echo "    App       : https://${GL_HOST}/${APP_GROUP}/${APP}"
echo "    Codebase  : status=${st}  ciTool=gitlab (Tekton EventListener skipped)"
[ -n "$HAS_CI" ] && echo "    .gitlab-ci.yml: injected by codebase-operator ✓" || echo "    (warn) .gitlab-ci.yml not found yet — check codebase-operator logs"
echo "    Webhooks  : $(api GET "projects/$(enc "$APP_GROUP/$APP")/hooks" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print("?")') (expected 0 — GitLab CI, not Tekton)"
echo "    Validate  : make e2e-gitlabci"
