# GitLab bootstrap helpers. Sourced; requires KUBECTL. Sets an EXIT trap that removes GL_TMP.
#   gl_rails SCRIPT [KEY=VALUE...]   run scripts/gitlab-rails/SCRIPT in the GitLab pod
#   json_get FIELD                   read one field of the gl_rails JSON from stdin
#   apply_secret NS NAME DIR         Secret NAME in existing namespace NS, one key per file in DIR
#   onboard_gitlab_user KEY=VALUE... ensure a user (scripts/gitlab-rails/user.rb); stdout: its new token
# apply_secret reads credentials from files under GL_TMP (mode 700), not from command arguments.

GL_NS="${GL_NS:-gitlab}"
GL_RAILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../gitlab-rails" && pwd)"
GL_TMP="$(umask 077; mktemp -d)"
trap 'rm -rf "$GL_TMP"' EXIT

# KEY=VALUE becomes env GR_<KEY>. A value @PATH uploads the local file; the script gets its pod path.
# stdout: the JSON passed to result(). On failure: the Ruby error message, return 1.
gl_rails() {
  local script="$1"; shift
  local pod work kv key val n=0 out rc=0 json env=()
  pod="$($KUBECTL -n "$GL_NS" get pod -l app=gitlab -o jsonpath='{.items[0].metadata.name}')"
  work="/tmp/gl-rails.$$.$RANDOM"
  # The runner runs as user git: work files must be world-readable (scripts, avatars, public keys).
  cat "$GL_RAILS_DIR/_lib.rb" "$GL_RAILS_DIR/$script" \
    | $KUBECTL -n "$GL_NS" exec -i "$pod" -- sh -c "mkdir -m 755 '$work' && cat > '$work/script.rb'"
  for kv in "$@"; do
    key="$(printf '%s' "${kv%%=*}" | tr '[:lower:]' '[:upper:]')"
    val="${kv#*=}"
    if [ "${val#@}" != "$val" ]; then
      [ -s "${val#@}" ] || { echo "FAIL gl_rails $script: file not found: ${val#@}" >&2; return 1; }
      # Keeps the file name: GitLab validates uploads by extension.
      n=$((n + 1))
      $KUBECTL -n "$GL_NS" exec -i "$pod" -- sh -c "mkdir '$work/$n' && cat > '$work/$n/$(basename "${val#@}")'" <"${val#@}"
      val="$work/$n/$(basename "${val#@}")"
    fi
    env+=("GR_$key=$val")
  done
  out="$($KUBECTL -n "$GL_NS" exec "$pod" -- env ${env[@]+"${env[@]}"} gitlab-rails runner "$work/script.rb" 2>"$GL_TMP/rails.err")" || rc=$?
  $KUBECTL -n "$GL_NS" exec "$pod" -- rm -rf "$work" || true
  json="$(printf '%s\n' "$out" | sed -n 's/^GL_RAILS_RESULT //p' | tail -1)"
  if [ "$rc" -ne 0 ] || [ -z "$json" ]; then
    echo "FAIL gl_rails $script (exit $rc):" >&2
    grep -v '^[[:space:]]*from ' "$GL_TMP/rails.err" | tail -20 >&2
    return 1
  fi
  printf '%s\n' "$json"
}

# Fails on a missing or null field.
json_get() {
  python3 -I -c 'import json,sys
v = json.load(sys.stdin).get(sys.argv[1])
if v is None: sys.exit("json_get: field %s missing or null" % sys.argv[1])
sys.stdout.write(v if isinstance(v, str) else json.dumps(v))' "$1"
}

apply_secret() {
  local ns="$1" name="$2" dir="$3"
  $KUBECTL get namespace "$ns" >/dev/null 2>&1 || { echo "FAIL namespace $ns not found" >&2; return 1; }
  $KUBECTL -n "$ns" create secret generic "$name" --from-file="$dir" --dry-run=client -o yaml \
    | $KUBECTL apply -f - >/dev/null
  echo "    secret $ns/$name applied (keys: $(ls "$dir" | paste -sd " " -))"
}

# Parameters: scripts/gitlab-rails/user.rb; token_name required. Summary on stderr.
onboard_gitlab_user() {
  local res
  res="$(gl_rails user.rb "$@")" || return 1
  echo "    $(printf '%s' "$res" | json_get summary)" >&2
  printf '%s' "$res" | json_get token
}
