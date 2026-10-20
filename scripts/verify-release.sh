#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
archive=${OTTO_ARCHIVE:-${MUSE_ARCHIVE:-$repository_root/.build/distribution/Otto-0.1.0.zip}}
verification_dir=$(mktemp -d /tmp/otto-release-verification.XXXXXX)
trap '/bin/rm -rf "$verification_dir"' EXIT

/usr/bin/unzip -t "$archive"
/usr/bin/shasum -a 256 -c "$archive.sha256"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc -x -k "$archive" "$verification_dir"
app_bundle=$verification_dir/Otto.app
/usr/bin/plutil -lint "$app_bundle/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"
test -s "$app_bundle/Contents/Resources/AppIcon.icns"
test "$(/usr/bin/plutil -extract CFBundleIconFile raw "$app_bundle/Contents/Info.plist")" = AppIcon
test -x "$app_bundle/Contents/MacOS/Otto"
test -x "$app_bundle/Contents/MacOS/ottoctl"
test -x "$app_bundle/Contents/MacOS/otto-mcp"
test -x "$app_bundle/Contents/MacOS/otto-hermes-bridge"
test -x "$app_bundle/Contents/MacOS/otto-openai-agent"
test -x "$app_bundle/Contents/MacOS/otto-hookd"
test -x "$app_bundle/Contents/MacOS/ottod"
test -f "$app_bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Resource bundles are flat with older toolchains and have Contents/Resources with newer ones.
bundle_file() {
  local bundle=$app_bundle/Contents/Resources/$1
  shift
  for name in "$@"; do
    test -f "$bundle/$name" || test -f "$bundle/Contents/Resources/$name" && return 0
  done
  print -u2 "Missing from ${bundle:t}: $*"
  return 1
}
bundle_file SwiftTerm_SwiftTerm.bundle Shaders.metal default.metallib
bundle_file Otto_OttoServices.bundle PhotonBridge/bridge.mjs
bundle_file Otto_OttoServices.bundle PhotonBridge/package-lock.json
"$app_bundle/Contents/MacOS/ottoctl" --help >/dev/null
"$app_bundle/Contents/MacOS/otto-mcp" --help >/dev/null
"$app_bundle/Contents/MacOS/otto-hermes-bridge" --version >/dev/null
"$app_bundle/Contents/MacOS/otto-openai-agent" --version >/dev/null
"$app_bundle/Contents/MacOS/ottod" --help >/dev/null
