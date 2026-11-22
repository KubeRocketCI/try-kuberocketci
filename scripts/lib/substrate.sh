# Agent Substrate helpers. Sourced; requires KUBECTL_ATE (kubectl ate --context <ctx>) and set -e.
#   ate_run WHAT ARGS...                 kubectl ate ARGS; stdout passes through. On failure: FAIL WHAT
#                                        with stderr (Warning lines dropped), exit 1.
#   ate_policy_grant SCOPE ROLE MEMBER   add binding ROLE -> MEMBER to the access policy of SCOPE
#                                        (atespace name, or --global). Existing bindings are kept;
#                                        the policy is created when absent; no write when present.
#                                        One binding per role (server rule): MEMBER joins the
#                                        binding of ROLE when it exists.
# kubectl ate get access-policy: exit 0 and empty stdout when the policy does not exist.

ate_run() {
  local what="$1" err rc=0
  shift
  err="$(mktemp)"
  $KUBECTL_ATE "$@" 2>"$err" || rc=$?
  if [ "$rc" != 0 ]; then
    echo "FAIL $what: $(grep -v '^Warning' "$err")" >&2
    rm -f "$err"
    exit 1
  fi
  rm -f "$err"
}

ate_policy_grant() {
  local scope=(-a "$1") label="atespace $1" role="$2" member="$3" cur
  if [ "$1" = --global ]; then scope=(--global) label=global; fi
  cur="$(ate_run "$label access policy read" get access-policy "${scope[@]}" -o json)"
  if [ -z "$cur" ]; then
    printf 'bindings:\n- role: %s\n  members:\n  - %s\n' "$role" "$member" \
      | ate_run "$label access policy create" create access-policy "${scope[@]}" -f - >/dev/null
    echo "    $label access policy: created, $role $member"
  elif jq -e --arg r "$role" --arg m "$member" \
    'any(.bindings[]?; .role == $r and ((.members // []) | index($m)))' <<<"$cur" >/dev/null; then
    echo "    $label access policy: $role $member present"
  else
    jq --arg r "$role" --arg m "$member" 'del(.metadata.atespace)
      | if any(.bindings[]?; .role == $r)
        then .bindings |= map(if .role == $r then .members = ((.members // []) + [$m]) else . end)
        else .bindings = ((.bindings // []) + [{role: $r, members: [$m]}]) end' <<<"$cur" \
      | ate_run "$label access policy update" update access-policy "${scope[@]}" -f - >/dev/null
    echo "    $label access policy: $role $member added"
  fi
}
