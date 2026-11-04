#!/bin/zsh
# Publishes an Otto Desktop (Windows + Linux) release built by CI, the way publish-release.sh
# publishes the Mac app:
#   1. downloads the installers the Desktop workflow built for the release commit,
#   2. writes the signed desktop manifest (Ed25519 release key from the login Keychain) that every
#      installed copy checks before it runs an update,
#   3. uploads the installers to a GitHub release (desktop-v<version>) in the releases repo,
#   4. pushes the update feed (latest.yml, latest-linux.yml, manifest.json) to its Pages site.
#
# usage: scripts/publish-desktop-release.sh <version> <ci-run-id>
#        OTTO_DRY_RUN=<folder> scripts/publish-desktop-release.sh …  prepares and checks everything,
#        writes the unsigned manifest and feed files to <folder>, and signs, uploads and pushes nothing.
#   The run must be a green Desktop workflow run whose packages carry <version>
#   (Apps/OttoDesktop/package.json "version").
set -euo pipefail

version=${1:?version, e.g. 0.2.0}
run_id=${2:?the Desktop workflow run that built it}
ci_repo=${OTTO_DESKTOP_CI_REPO:-maxtrigify/Otto}
releases_repo=${OTTO_RELEASES_REPO:-maxtrigify/muse-releases}
releases_checkout=${OTTO_RELEASES_CHECKOUT:-$HOME/Documents/muse-releases}
signing_key_id=${OTTO_SIGNING_KEY_ID:-muse-2026-1}
tag="desktop-v$version"
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must be x.y.z" >&2; exit 64; }
command -v gh > /dev/null || { echo "Install gh (brew install gh)" >&2; exit 69; }

conclusion=$(gh run view "$run_id" --repo "$ci_repo" --json conclusion,workflowName --jq '.workflowName + ":" + .conclusion')
[[ $conclusion == "Desktop:success" ]] || { echo "Run $run_id is $conclusion, not a green Desktop run" >&2; exit 65; }

echo "Downloading installers from run $run_id…"
gh run download "$run_id" --repo "$ci_repo" --name otto-windows-installer --dir "$work/win"
gh run download "$run_id" --repo "$ci_repo" --name otto-linux-packages --dir "$work/linux"
files=("$work"/win/*.exe "$work"/linux/*.AppImage "$work"/linux/*.deb)
# Blockmaps let Windows download only what changed between versions.
blockmaps=("$work"/win/*.blockmap(N))
for file in $files; do
  [[ $(basename "$file") == *"$version"* ]] || { echo "$(basename "$file") is not version $version" >&2; exit 65; }
done
[[ -f $work/win/latest.yml && -f $work/linux/latest-linux.yml ]] || { echo "The run has no update feed files" >&2; exit 65; }

base="https://github.com/$releases_repo/releases/download/$tag"
echo "Writing the signed manifest…"
node - "$work" "$version" "$base" <<'EOF'
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const [work, version, base] = process.argv.slice(2);
const entries = [];
for (const [folder, platform] of [['win', 'win32'], ['linux', 'linux']]) {
  for (const name of fs.readdirSync(path.join(work, folder))) {
    const kind = name.endsWith('.exe') ? 'nsis' : name.endsWith('.AppImage') ? 'appimage' : name.endsWith('.deb') ? 'deb' : null;
    if (!kind) continue;
    const bytes = fs.readFileSync(path.join(work, folder, name));
    const arch = /arm64|aarch64/.test(name) ? 'arm64' : 'x64';
    entries.push({ platform, arch, kind, name, url: `${base}/${encodeURIComponent(name)}`, sha512: crypto.createHash('sha512').update(bytes).digest('base64'), size: bytes.length });
  }
}
fs.writeFileSync(path.join(work, 'manifest.json'), JSON.stringify({ product: 'otto-desktop', version, releasedAt: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), files: entries }, null, 2));
// The feed files name installers relative to the feed; point them at the GitHub release.
for (const feed of ['win/latest.yml', 'linux/latest-linux.yml']) {
  const file = path.join(work, feed);
  const text = fs.readFileSync(file, 'utf8').replace(/^(\s*-?\s*url:\s*)(\S+)$/gm, (_, prefix, name) => `${prefix}${base}/${name}`).replace(/^path:\s*(\S+)$/m, (_, name) => `path: ${base}/${name}`);
  fs.writeFileSync(file, text);
}
EOF
if [[ -n ${OTTO_DRY_RUN:-} ]]; then
  mkdir -p "$OTTO_DRY_RUN"
  cp "$work/manifest.json" "$work/win/latest.yml" "$work/linux/latest-linux.yml" "$OTTO_DRY_RUN/"
  echo "Dry run: wrote the manifest and feed files to $OTTO_DRY_RUN; nothing was signed or published."
  exit 0
fi
signing_key=$(security find-generic-password -s otto-release-signing -w 2>/dev/null \
  || security find-generic-password -s muse-release-signing -w)
release_bin=$("$root/scripts/otto-swift" build -c release --product otto-release --show-bin-path \
  | /usr/bin/tail -n 1)
release_tool=$release_bin/otto-release
[[ -x $release_tool ]] || { echo "The guarded SwiftPM build did not produce otto-release." >&2; exit 2; }
OTTO_SIGNING_PRIVATE_KEY=$signing_key OTTO_SIGNING_KEY_ID=$signing_key_id \
  "$release_tool" sign-desktop-manifest "$work/manifest.json" "$work/signed-manifest.json"
unset signing_key

echo "Uploading $tag to $releases_repo…"
if gh release view "$tag" --repo "$releases_repo" > /dev/null 2>&1; then
  gh release upload "$tag" $files $blockmaps --repo "$releases_repo" --clobber
else
  gh release create "$tag" $files $blockmaps --repo "$releases_repo" --title "Otto Desktop $version" \
    --notes "Otto for Windows and Linux, version $version."
fi

echo "Publishing the update feed…"
[[ -d $releases_checkout/.git ]] || gh repo clone "$releases_repo" "$releases_checkout"
git -C "$releases_checkout" pull --ff-only
mkdir -p "$releases_checkout/desktop"
cp "$work/win/latest.yml" "$work/linux/latest-linux.yml" "$releases_checkout/desktop/"
cp "$work/signed-manifest.json" "$releases_checkout/desktop/manifest.json"
git -C "$releases_checkout" add desktop
git -C "$releases_checkout" commit -m "Release Otto Desktop $version"
git -C "$releases_checkout" push
echo "Otto Desktop $version is live: installed copies pick it up within six hours."
