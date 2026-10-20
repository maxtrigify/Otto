#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
version=${OTTO_VERSION:-${MUSE_VERSION:-0.1.0}}
archive=${OTTO_ARCHIVE:-${MUSE_ARCHIVE:-$repository_root/.build/distribution/Otto-$version.zip}}
profile=${OTTO_NOTARY_PROFILE:-${MUSE_NOTARY_PROFILE:-}}
staging_dir=$(mktemp -d /tmp/otto-notarization.XXXXXX)
app_bundle=$staging_dir/Otto.app
trap '/bin/rm -rf "$staging_dir"' EXIT

if [[ -z $profile ]]; then
  print -u2 "Set OTTO_NOTARY_PROFILE to a notarytool Keychain profile."
  exit 2
fi
if [[ ! -f $archive ]]; then
  print -u2 "Package Otto before notarising it."
  exit 2
fi

xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc -x -k "$archive" "$staging_dir"
xcrun stapler staple "$app_bundle"
xcrun stapler validate "$app_bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"
/bin/rm -f "$archive" "$archive.sha256"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc -c -k --keepParent "$app_bundle" "$archive"
/usr/bin/shasum -a 256 "$archive" > "$archive.sha256"
