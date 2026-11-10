#!/usr/bin/env bash
# Optional Agent Substrate install, not part of `make testbed`. Upstream: release notes "Install".
#   * kind nodes: net.ipv4.conf.all.proxy_arp=1 (gVisor loopback networking). Runtime sysctl:
#     re-run after a Docker Desktop restart.
#   * checkout of SUBSTRATE_VERSION in .cache/substrate/<version>: installer and manifests.
#   * ate-setup deploy ate-system: release images, settings in values/substrate-install.yaml.
#   * kubectl-ate release binary in .cache/substrate/<version>/bin, checked against the hashes
#     pinned in values/substrate-kubectl-ate.sha256 (replace them with the release's on a version change).
set -euo pipefail

VER="${SUBSTRATE_VERSION:?SUBSTRATE_VERSION is required}"
CLUSTER="${CLUSTER:?CLUSTER is required}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/.cache/substrate/$VER"
REL="https://github.com/agent-substrate/substrate/releases/download/$VER"
PINNED="$HERE/values/substrate-kubectl-ate.sha256"

echo "==> kind nodes of $CLUSTER: proxy_arp"
for node in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$node" sysctl -q net.ipv4.conf.all.proxy_arp=1
done

echo "==> Substrate $VER checkout: $SRC"
if [ ! -d "$SRC" ]; then
  mkdir -p "$(dirname "$SRC")"
  TMP_SRC="$(mktemp -d "$SRC.XXXXXX")"
  trap 'rm -rf "$TMP_SRC"' EXIT
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$VER" https://github.com/agent-substrate/substrate.git "$TMP_SRC"
  mv "$TMP_SRC" "$SRC"
fi

echo "==> ate-setup deploy ate-system"
go -C "$SRC" run ./cmd/ate-setup deploy ate-system --config "$HERE/values/substrate-install.yaml" \
  --kind-cluster-name "$CLUSTER" --image-tag "$VER"

echo "==> kubectl-ate $VER"
f="kubectl-ate-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m | sed 's/^x86_64$/amd64/')"
want="$(grep -E "  $f\$" "$PINNED" || true)"
[ -n "$want" ] || { echo "FAIL no pinned sha256 for $f in $PINNED" >&2; exit 1; }
mkdir -p "$SRC/bin"
curl -fsSL -o "$SRC/bin/$f" "$REL/$f"
(cd "$SRC/bin" && printf '%s\n' "$want" | shasum -a 256 -c -) | sed 's/^/    /'
install -m 0755 "$SRC/bin/$f" "$SRC/bin/kubectl-ate"
echo "    export PATH=\"$SRC/bin:\$PATH\""
