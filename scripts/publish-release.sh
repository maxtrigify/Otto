#!/bin/zsh
# Publishes an Otto release end to end:
#   package → verify → (notarize) → sign update manifest → push site data → GitHub release.
#
# Usage: scripts/publish-release.sh <version> <build-number>
#
# Requirements:
#   - gh CLI authenticated with access to $OTTO_RELEASES_REPO.
#   - Ed25519 release key in the login Keychain (service otto-release-signing; the pre-rename
#     service muse-release-signing is read when the new one does not exist).
#   - A checkout of the releases repo at $OTTO_RELEASES_CHECKOUT (cloned automatically if absent).
#   - Optional: OTTO_CODESIGN_IDENTITY / OTTO_NOTARY_PROFILE for Developer ID + notarized builds.
#   The pre-rename MUSE_* names are still read when the OTTO_* one is unset. The feed repo
#   (maxtrigify/muse-releases) and key id (muse-2026-1) keep their names: every installed
#   updater depends on them.
set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}

version=${1:?usage: publish-release.sh <version> <build-number>}
build_number=${2:?usage: publish-release.sh <version> <build-number>}

releases_repo=${OTTO_RELEASES_REPO:-${MUSE_RELEASES_REPO:-maxtrigify/muse-releases}}
releases_checkout=${OTTO_RELEASES_CHECKOUT:-${MUSE_RELEASES_CHECKOUT:-$HOME/Documents/muse-releases}}
signing_key_id=${OTTO_SIGNING_KEY_ID:-${MUSE_SIGNING_KEY_ID:-muse-2026-1}}
minimum_macos=${OTTO_MINIMUM_MACOS:-${MUSE_MINIMUM_MACOS:-15.0}}
tag=v$version
archive=$repository_root/.build/distribution/Otto-$version.zip
artifact_url=https://github.com/$releases_repo/releases/download/$tag/Otto-$version.zip
dmg=$repository_root/.build/distribution/Otto-$version.dmg
download_url=https://github.com/$releases_repo/releases/download/$tag/Otto-$version.dmg

# --- 1. Release notes must exist before anything is built. ---------------------------------
notes=$(awk -v ver="$version" '
  $0 ~ "^## "ver" " || $0 ~ "^## "ver"$" { capture = 1; next }
  capture && /^## / { exit }
  capture { print }
' "$repository_root/CHANGELOG.md")
if [[ -z ${notes// /} ]]; then
  print -u2 "CHANGELOG.md has no section '## $version — …'. Write the changelog first."
  exit 2
fi

# --- 2. Build, package, verify (and notarize when credentials are configured). -------------
export OTTO_VERSION=$version OTTO_BUILD_NUMBER=$build_number OTTO_ARCHIVE=$archive
"$script_dir/package-macos.sh"
"$script_dir/verify-release.sh"
if [[ -n ${OTTO_NOTARY_PROFILE:-${MUSE_NOTARY_PROFILE:-}} ]]; then
  "$script_dir/notarize-macos.sh"
else
  print "OTTO_NOTARY_PROFILE not set — publishing an ad-hoc signed build (right-click → Open)."
fi

"$script_dir/create-dmg.sh"

sha256=$(/usr/bin/shasum -a 256 "$archive" | cut -d' ' -f1)
byte_count=$(/usr/bin/stat -f%z "$archive")
generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
release_date=$(date -u +%Y-%m-%d)

# --- 3. Produce and sign the update manifest. ----------------------------------------------
work_dir=$(mktemp -d /tmp/otto-publish.XXXXXX)
trap '/bin/rm -rf "$work_dir"' EXIT

NOTES="$notes" python3 - "$work_dir/manifest.json" <<PY
import json, os, sys
# Swift's Codable encodes [ReleaseChannel: UpdateRelease] as a flat [key, value, ...] array,
# so the manifest must use that shape for otto-release / the app to decode it.
manifest = {
    "generatedAt": "$generated_at",
    "releases": [
        "stable",
        {
            "version": "$version",
            "build": $build_number,
            "artifactURL": "$artifact_url",
            "sha256": "$sha256",
            "byteCount": $byte_count,
            "minimumMacOSVersion": "$minimum_macos",
            "changelog": os.environ["NOTES"].strip(),
            "rolloutPercentage": 100,
        },
    ],
    "blockedVersions": [],
}
with open(sys.argv[1], "w") as handle:
    json.dump(manifest, handle, indent=2)
PY

release_bin=$("$script_dir/otto-swift" build -c release --product otto-release --show-bin-path \
  | /usr/bin/tail -n 1)
release_tool=$release_bin/otto-release
[[ -x $release_tool ]] || {
  print -u2 "The guarded SwiftPM build did not produce otto-release."
  exit 2
}
# otto-release-signing, falling back to the key stored before the rename. Nothing is copied:
# the key stays wherever it already is.
signing_key=$(security find-generic-password -s otto-release-signing -w 2>/dev/null \
  || security find-generic-password -s muse-release-signing -w)
OTTO_SIGNING_PRIVATE_KEY=$signing_key OTTO_SIGNING_KEY_ID=$signing_key_id \
  "$release_tool" sign-manifest "$work_dir/manifest.json" "$work_dir/signed-manifest.json"
unset signing_key

# --- 4. Update the public releases repo (site data + signed manifest). ---------------------
if [[ ! -d $releases_checkout/.git ]]; then
  gh repo clone "$releases_repo" "$releases_checkout"
fi
git -C "$releases_checkout" pull --ff-only

/bin/mkdir -p "$releases_checkout/v1/updates"
/bin/cp "$work_dir/signed-manifest.json" "$releases_checkout/v1/updates/manifest"

NOTES="$notes" python3 - "$releases_checkout" <<PY
import json, os, sys
root = sys.argv[1]
entry = {
    "version": "$version",
    "build": $build_number,
    "date": "$release_date",
    "notes": os.environ["NOTES"].strip(),
}
latest = {
    "version": "$version",
    "build": $build_number,
    "date": "$release_date",
    "artifactURL": "$artifact_url",
    "downloadURL": "$download_url",
    "sha256": "$sha256",
    "byteCount": $byte_count,
    "minimumMacOSVersion": "$minimum_macos",
}
with open(os.path.join(root, "updates.json"), "w") as handle:
    json.dump(latest, handle, indent=2)
path = os.path.join(root, "changelog.json")
history = []
if os.path.exists(path):
    with open(path) as handle:
        history = json.load(handle)
history = [item for item in history if item["version"] != "$version"]
history.insert(0, entry)
with open(path, "w") as handle:
    json.dump(history, handle, indent=2)
PY

git -C "$releases_checkout" add v1 updates.json changelog.json
git -C "$releases_checkout" commit -m "Release Otto $version (build $build_number)"

# --- 5. Publish the artifact, then the manifest that points at it. -------------------------
if gh release view "$tag" --repo "$releases_repo" > /dev/null 2>&1; then
  gh release upload "$tag" "$archive" "$dmg" --repo "$releases_repo" --clobber
else
  gh release create "$tag" "$archive" "$dmg" --repo "$releases_repo" \
    --title "Otto $version" --notes "$notes"
fi
git -C "$releases_checkout" push

# --- 6. Mirror the source to the public repository and release it there too. ---------------
# Only the private checkout has the sync script; public builds skip this step.
public_repo=${OTTO_PUBLIC_REPO:-maxtrigify/Otto}
sync_script="$repository_root/Server/scripts/sync-open-source"
if [[ -x $sync_script ]]; then
  if public_sha=$("$sync_script" HEAD | tail -1) && [[ -n $public_sha ]]; then
    if gh release view "$tag" --repo "$public_repo" > /dev/null 2>&1; then
      gh release upload "$tag" "$archive" "$dmg" --repo "$public_repo" --clobber
    else
      gh release create "$tag" "$archive" "$dmg" --repo "$public_repo" \
        --target "$public_sha" --title "Otto $version" --notes "$notes"
    fi
    print "  public    https://github.com/$public_repo/releases/tag/$tag"
  else
    print -u2 "The release is published, but mirroring to $public_repo failed."
    print -u2 "Rerun: $sync_script HEAD, then create the $tag release on $public_repo."
  fi
fi

print "Published Otto $version (build $build_number)"
print "  artifact  $artifact_url"
print "  sha256    $sha256"
