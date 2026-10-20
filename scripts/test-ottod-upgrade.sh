#!/bin/sh
set -eu

release_tool=${OTTO_RELEASE_TOOL:-${MUSE_RELEASE_TOOL:-.build/release/otto-release}}
daemon=${OTTOD_BINARY:-${MUSED_BINARY:-.build/release/ottod}}
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/otto-upgrade-e2e.XXXXXX")
trap 'rm -r "$test_directory"' EXIT HUP INT TERM

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=macos-arm64 ;;
  Darwin-x86_64) platform=macos-x86_64 ;;
  Linux-aarch64 | Linux-arm64) platform=linux-arm64 ;;
  Linux-x86_64) platform=linux-x86_64 ;;
  *) printf '%s\n' "Unsupported upgrade test platform." >&2; exit 1 ;;
esac

test -x "$release_tool"
test -x "$daemon"

export OTTO_SIGNING_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
export OTTO_SIGNING_KEY_ID=upgrade-e2e
public_key=$($release_tool public-key)
$release_tool sign-remote-artifact \
  "$daemon" 0.2.0 2 "$platform" "$test_directory/signed-upgrade.json"

# `ottod` is the current install name; `mused` is what hosts set up before the rename still run.
for name in ottod mused; do
  cp /bin/echo "$test_directory/old-$name"
  cp "$test_directory/old-$name" "$test_directory/$name"
  $daemon install-upgrade \
    --manifest "$test_directory/signed-upgrade.json" \
    --artifact "$daemon" \
    --destination "$test_directory/$name" \
    --current-version 0.1.0 \
    --current-build 1 \
    --key-id upgrade-e2e \
    --public-key "$public_key" >"$test_directory/receipt-$name.json"

  cmp "$daemon" "$test_directory/$name"
  cmp "$test_directory/old-$name" "$test_directory/$name.previous"
  grep -q '"version":"0.2.0"' "$test_directory/receipt-$name.json"
done
printf '%s\n' "Signed $platform daemon upgrade and rollback artifact verified (ottod and mused)."
