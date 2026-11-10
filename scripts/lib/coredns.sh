# CoreDNS split-horizon helpers. Sourced; requires KUBECTL.
#   ensure_coredns_rewrite HOST TARGET   add "rewrite name HOST TARGET" when no rewrite for HOST exists;
#                                        sets COREDNS_CHANGED=1 on a change. The caller restarts CoreDNS.

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
