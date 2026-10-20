#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
configuration=${OTTO_BUILD_CONFIGURATION:-${MUSE_BUILD_CONFIGURATION:-release}}
version=${OTTO_VERSION:-${MUSE_VERSION:-0.1.0}}
build_number=${OTTO_BUILD_NUMBER:-${MUSE_BUILD_NUMBER:-1}}
signing_identity=${OTTO_CODESIGN_IDENTITY:-${MUSE_CODESIGN_IDENTITY:--}}
distribution_dir=${OTTO_DISTRIBUTION_DIR:-${MUSE_DISTRIBUTION_DIR:-$repository_root/.build/distribution}}
archive=$distribution_dir/Otto-$version.zip
staging_dir=$(mktemp -d /tmp/otto-package.XXXXXX)
app_bundle=$staging_dir/Otto.app
trap '/bin/rm -rf "$staging_dir"' EXIT

case $distribution_dir in
  $repository_root/.build/*) ;;
  *)
    print -u2 "OTTO_DISTRIBUTION_DIR must be inside $repository_root/.build"
    exit 2
    ;;
esac

"$script_dir/otto-swift" build \
  -c "$configuration" \
  -Xswiftc -warnings-as-errors
binary_dir=$("$script_dir/otto-swift" build \
  -c "$configuration" \
  --show-bin-path | /usr/bin/tail -n 1)
[[ -d $binary_dir ]] || {
  print -u2 "Could not locate the guarded SwiftPM product directory."
  exit 2
}

/bin/mkdir -p "$distribution_dir"
/bin/mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
/usr/bin/install -m 755 "$binary_dir/Otto" "$app_bundle/Contents/MacOS/Otto"
/usr/bin/install -m 755 "$binary_dir/ottoctl" "$app_bundle/Contents/MacOS/ottoctl"
/usr/bin/install -m 755 "$binary_dir/otto-mcp" "$app_bundle/Contents/MacOS/otto-mcp"
/usr/bin/install -m 755 "$binary_dir/otto-hermes-bridge" "$app_bundle/Contents/MacOS/otto-hermes-bridge"
/usr/bin/install -m 755 "$binary_dir/otto-openai-agent" "$app_bundle/Contents/MacOS/otto-openai-agent"
/usr/bin/install -m 755 "$binary_dir/otto-hookd" "$app_bundle/Contents/MacOS/otto-hookd"
/usr/bin/install -m 755 "$binary_dir/ottod" "$app_bundle/Contents/MacOS/ottod"
/usr/bin/install -m 644 "$repository_root/packaging/Info.plist" "$app_bundle/Contents/Info.plist"
/usr/bin/install -m 644 "$repository_root/packaging/AppIcon.icns" \
  "$app_bundle/Contents/Resources/AppIcon.icns"
/usr/bin/install -m 644 "$repository_root/packaging/THIRD_PARTY_NOTICES.md" "$app_bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
for resource_bundle in "$binary_dir/SwiftTerm_SwiftTerm.bundle" "$binary_dir/Otto_OttoApp.bundle" "$binary_dir/Otto_OttoServices.bundle"; do
  [[ -d $resource_bundle ]] || {
    print -u2 "Missing required resource bundle: $resource_bundle"
    exit 2
  }
  /usr/bin/ditto --norsrc "$resource_bundle" "$app_bundle/Contents/Resources/${resource_bundle:t}"
done
/bin/chmod -R u+w "$app_bundle"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$app_bundle/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$build_number" "$app_bundle/Contents/Info.plist"
"$repository_root/scripts/configure-private-phone" "$app_bundle/Contents/Info.plist"
"$repository_root/scripts/configure-google-app-client" "$app_bundle/Contents/Info.plist"
/usr/bin/plutil -lint "$app_bundle/Contents/Info.plist"
/usr/bin/xattr -cr "$app_bundle"

if [[ $signing_identity == - ]]; then
  codesign_options=(--force --sign - --timestamp=none)
else
  codesign_options=(--force --sign "$signing_identity" --timestamp --options runtime)
fi

/usr/bin/codesign "${codesign_options[@]}" "$app_bundle/Contents/MacOS/ottoctl"
/usr/bin/codesign "${codesign_options[@]}" "$app_bundle/Contents/MacOS/otto-mcp"
/usr/bin/codesign "${codesign_options[@]}" "$app_bundle/Contents/MacOS/otto-hermes-bridge"
/usr/bin/codesign "${codesign_options[@]}" "$app_bundle/Contents/MacOS/otto-openai-agent"
/usr/bin/codesign "${codesign_options[@]}" "$app_bundle/Contents/MacOS/otto-hookd"
/usr/bin/codesign "${codesign_options[@]}" "$app_bundle/Contents/MacOS/ottod"
/usr/bin/codesign "${codesign_options[@]}" --entitlements "$repository_root/packaging/Otto.entitlements" "$app_bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"

/bin/rm -f "$archive"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc -c -k --keepParent "$app_bundle" "$archive"
/usr/bin/shasum -a 256 "$archive" > "$archive.sha256"

print "$archive"
