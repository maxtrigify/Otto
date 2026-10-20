#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
version=${OTTO_VERSION:-${MUSE_VERSION:-0.1.0}}
distribution_dir=${OTTO_DISTRIBUTION_DIR:-${MUSE_DISTRIBUTION_DIR:-$repository_root/.build/distribution}}
archive=${OTTO_ARCHIVE:-${MUSE_ARCHIVE:-$distribution_dir/Otto-$version.zip}}
dmg=${OTTO_DMG:-${MUSE_DMG:-$distribution_dir/Otto-$version.dmg}}
staging_dir=$(mktemp -d /tmp/otto-dmg.XXXXXX)
source_dir=$staging_dir/source
read_write_dmg=$staging_dir/Otto-rw.dmg
mount_point=$staging_dir/mount
trap '/usr/bin/hdiutil detach "$mount_point" -quiet 2>/dev/null || true; /bin/rm -rf "$staging_dir"' EXIT

if [[ ! -f $archive ]]; then
  print -u2 "Missing packaged application: $archive"
  exit 2
fi

/bin/mkdir -p "$source_dir"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc -x -k "$archive" "$source_dir"
if [[ ! -d $source_dir/Otto.app ]]; then
  print -u2 "The package does not contain Otto.app."
  exit 2
fi

# Finder renders this as the familiar drag-to-Applications installer: the app on
# the left and a real Applications-folder alias on the right.
/bin/ln -s /Applications "$source_dir/Applications"
/usr/bin/install -m 644 "$repository_root/packaging/AppIcon.icns" "$source_dir/.VolumeIcon.icns"

/bin/rm -f "$dmg" "$dmg.sha256"
COPYFILE_DISABLE=1 /usr/bin/hdiutil create \
  -volname "Otto" \
  -srcfolder "$source_dir" \
  -format UDRW \
  -ov "$read_write_dmg"

/bin/mkdir -p "$mount_point"
/usr/bin/hdiutil attach "$read_write_dmg" -mountpoint "$mount_point" -readwrite -noverify -noautoopen

# Persist a conventional Finder layout into .DS_Store: Otto on the left,
# Applications on the right, ready for the user to drag across.
if [[ ${OTTO_DMG_SKIP_FINDER_LAYOUT:-${MUSE_DMG_SKIP_FINDER_LAYOUT:-0}} != 1 ]]; then
/usr/bin/osascript <<APPLESCRIPT
tell application "Finder"
  set mountedFolder to POSIX file "$mount_point" as alias
  open mountedFolder
  delay 2
  set installerWindow to container window of mountedFolder
  set current view of installerWindow to icon view
  set toolbar visible of installerWindow to false
  set statusbar visible of installerWindow to false
  set pathbar visible of installerWindow to false
  set bounds of installerWindow to {180, 180, 800, 580}
  set arrangement of icon view options of installerWindow to not arranged
  set icon size of icon view options of installerWindow to 112
  set text size of icon view options of installerWindow to 14
  set position of item "Otto.app" of mountedFolder to {155, 185}
  set position of item "Applications" of mountedFolder to {455, 185}
  update mountedFolder without registering applications
  delay 1
  close installerWindow
end tell
APPLESCRIPT
fi

/bin/sync
/usr/bin/hdiutil detach "$mount_point" -quiet
/usr/bin/hdiutil convert "$read_write_dmg" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov -o "$dmg"

notary_profile=${OTTO_NOTARY_PROFILE:-${MUSE_NOTARY_PROFILE:-}}
if [[ -n $notary_profile ]]; then
  /usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
  /usr/bin/xcrun stapler staple "$dmg"
  /usr/bin/xcrun stapler validate "$dmg"
fi

/usr/bin/hdiutil verify "$dmg"
/usr/bin/shasum -a 256 "$dmg" > "$dmg.sha256"
print "$dmg"
