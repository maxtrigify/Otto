#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s) != Linux ]]; then
  printf 'package-ottod-linux.sh must run on Linux.\n' >&2
  exit 64
fi

version=${OTTO_VERSION:-${MUSE_VERSION:-0.1.0}}
architecture=$(uname -m)
strip_tool=${OTTO_STRIP_TOOL:-${MUSE_STRIP_TOOL:-strip}}
distribution_dir="$repository_root/.build/distribution"
stage=$(mktemp -d /tmp/ottod-linux-package.XXXXXX)
trap 'rm -rf -- "$stage"' EXIT

if ! command -v "$strip_tool" >/dev/null 2>&1; then
  printf 'Required strip tool not found: %s\n' "$strip_tool" >&2
  exit 69
fi

swift build \
  --package-path "$repository_root" \
  --scratch-path "$repository_root/.build/linux-release" \
  -c release \
  --product ottod \
  -Xswiftc -warnings-as-errors

name="ottod-$version-linux-$architecture"
install -d -m 755 "$stage/$name"
install -m 755 "$repository_root/.build/linux-release/release/ottod" "$stage/$name/ottod"
"$strip_tool" --strip-all "$stage/$name/ottod"
install -m 644 "$repository_root/packaging/ottod.service" "$stage/$name/ottod.service"
install -m 755 "$repository_root/scripts/install-ottod-linux.sh" \
  "$stage/$name/install-ottod-linux.sh"
install -m 644 "$repository_root/docs/REMOTE_AGENTS.md" "$stage/$name/README.md"

mkdir -p "$distribution_dir"
artifact="$distribution_dir/$name.tar.gz"
tar -C "$stage" -czf "$artifact" "$name"
sha256sum "$artifact" >"$artifact.sha256"
printf '%s\n' "$artifact"
