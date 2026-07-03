#!/usr/bin/env bash
# Regenerate pkgs/wazuh-agent/deps.json for a Wazuh version bump.
#
# Usage:
#   scripts/update-deps.sh [WAZUH_VERSION [DEPS_VER]]
#   nix run .#update -- [WAZUH_VERSION [DEPS_VER]]
#
# With no arguments it re-prefetches the pinned version (a no-op round-trip,
# useful to verify the script and the URLs still work).  With a version it
# prefetches the new source tarball and every external dependency and
# rewrites deps.json.  DEPS_VER defaults to the currently pinned deps
# release; the script prints the release upstream builds against
# (DEPS_VERSION in src/Makefile) so you can decide whether to pass it.
#
# The dependency *names* are taken from the existing deps.json.  If upstream
# adds or removes an external dependency, add/remove the key there by hand —
# the build (make) will tell you via a missing-directory error.
#
# After updating: nix build .#wazuh-agent — the grep guards in the
# derivation catch upstream changes that break the Nix patches.
#
# Requires: git, curl, jq, nix (nix-prefetch-github is run via nix run if
# not on PATH).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
deps_json=$repo_root/pkgs/wazuh-agent/deps.json

current_version=$(jq -r .version "$deps_json")
version=${1:-$current_version}
deps_ver=${2:-$(jq -r .depsVer "$deps_json")}

# Informational: the deps release this Wazuh version is built against
# upstream.  The flake may deliberately pin a different (newer) one.
upstream_deps_ver=$(curl -fsSL "https://raw.githubusercontent.com/wazuh/wazuh/v${version}/src/Makefile" |
  sed -n 's/^DEPS_VERSION[[:space:]]*=[[:space:]]*//p' | head -1 | tr -d '[:space:]')
echo "wazuh v${version}: upstream DEPS_VERSION=${upstream_deps_ver:-unknown}, prefetching deps release ${deps_ver}"
if [ -n "$upstream_deps_ver" ] && [ "$upstream_deps_ver" != "$deps_ver" ]; then
  echo "note: differs from the pinned release; pass '${upstream_deps_ver}' as second argument to switch" >&2
fi

# SRI hash of a plain file download
prefetch_file() {
  nix store prefetch-file --json "$1" | jq -r .hash
}

# SRI hash of the wazuh source (needs submodules, hence nix-prefetch-github)
prefetch_src() {
  local out hash
  if command -v nix-prefetch-github > /dev/null; then
    out=$(nix-prefetch-github --fetch-submodules --rev "v${version}" wazuh wazuh)
  else
    out=$(nix run nixpkgs#nix-prefetch-github -- --fetch-submodules --rev "v${version}" wazuh wazuh)
  fi
  hash=$(jq -r '.hash // .sha256' <<< "$out")
  case $hash in
    sha256-*) echo "$hash" ;;
    *) nix hash convert --hash-algo sha256 --to sri "$hash" ;;
  esac
}

echo "prefetching wazuh source v${version} (with submodules, can take a while)..."
src_hash=$(prefetch_src)
echo "  srcHash: $src_hash"

base="https://packages.wazuh.com/deps/${deps_ver}/libraries/sources"
mapfile -t dep_names < <(jq -r '.deps | keys[]' "$deps_json")

deps_obj='{}'
for name in "${dep_names[@]}"; do
  echo "prefetching ${name}..."
  hash=$(prefetch_file "$base/${name}.tar.gz")
  deps_obj=$(jq --arg n "$name" --arg h "$hash" '. + {($n): $h}' <<< "$deps_obj")
done

# nlohmann lives in a separate deps release, capped at 21 by upstream.
echo "prefetching nlohmann (deps release 21)..."
nlohmann_hash=$(prefetch_file "https://packages.wazuh.com/deps/21/libraries/sources/nlohmann.tar.gz")

jq -n \
  --arg version "$version" \
  --arg depsVer "$deps_ver" \
  --arg srcHash "$src_hash" \
  --arg nlohmann "$nlohmann_hash" \
  --argjson deps "$deps_obj" \
  '{version: $version, depsVer: $depsVer, srcHash: $srcHash, nlohmann: $nlohmann, deps: $deps}' \
  > "${deps_json}.new"
mv "${deps_json}.new" "$deps_json"

echo
echo "wrote $deps_json"
git -C "$repo_root" --no-pager diff --stat -- "$deps_json" || true
echo
echo "next: nix build .#wazuh-agent"
