#!/bin/zsh
set -euo pipefail
setopt extendedglob

# Builds Otto.app (production) from the approved `main` branch and installs it.
# Unlike dev-app.sh, this never builds your working tree: sources come from a
# dedicated read-only git worktree pinned to `main`, so uncommitted dev work
# cannot leak into the prod app.

script_dir=${0:A:h}
repository_root=${OTTO_PROD_REPOSITORY_PATH:-${MUSE_PROD_REPOSITORY_PATH:-${script_dir:h}}}
prod_ref=${OTTO_PROD_REF:-${MUSE_PROD_REF:-main}}
app_path=${OTTO_PROD_APP_PATH:-${MUSE_PROD_APP_PATH:-/Applications/Otto.app}}
# Reuse an existing pre-rename checkout and build cache under ~/Library/Caches/Muse rather than
# starting cold; the app moves that folder to ~/Library/Caches/Otto (leaving a symlink).
caches_root=$HOME/Library/Caches/Otto
if [[ ! -e $caches_root/prod-checkout && -d $HOME/Library/Caches/Muse/prod-checkout ]]; then
  default_checkout_path=$HOME/Library/Caches/Muse/prod-checkout
else
  default_checkout_path=$caches_root/prod-checkout
fi
if [[ ! -e $caches_root/SwiftPM/macos-prod && -d $HOME/Library/Caches/Muse/SwiftPM/macos-prod ]]
then
  default_scratch_path=$HOME/Library/Caches/Muse/SwiftPM/macos-prod
else
  default_scratch_path=$caches_root/SwiftPM/macos-prod
fi
checkout_path=${OTTO_PROD_CHECKOUT_PATH:-${MUSE_PROD_CHECKOUT_PATH:-$default_checkout_path}}
scratch_path=${OTTO_PROD_SCRATCH_PATH:-${MUSE_PROD_SCRATCH_PATH:-$default_scratch_path}}
lock_directory=${OTTO_PROD_LOCK_DIRECTORY:-${MUSE_PROD_LOCK_DIRECTORY:-/tmp/otto-prod-build-$UID.lock}}
version=${OTTO_VERSION:-${MUSE_VERSION:-0.1.0}}
local_identity_name="Otto Local Development"
# Identity created by dev-app.sh before the rename; still used when the new one is absent.
legacy_identity_name="Muse Local Development"

# Builds from before the Otto rename installed "Muse.app" (bundle app.muse.desktop) beside the
# new app. Move the old copy to the Trash once the new one is in place; Otto's launch migration
# carries its data over.
retire_legacy_app() {
  local legacy="${app_path:h}/Muse.app" identifier
  [[ $legacy != "$app_path" && -d $legacy ]] || return 0
  identifier=$(/usr/bin/defaults read "$legacy/Contents/Info" CFBundleIdentifier 2>/dev/null) \
    || return 0
  [[ $identifier == app.muse.desktop ]] || return 0
  /bin/mkdir -p "$HOME/.Trash"
  if /bin/mv "$legacy" "$HOME/.Trash/Muse $(/bin/date +%Y%m%d%H%M%S).app"; then
    print "Moved the pre-rename Muse.app to the Trash: $legacy"
  else
    print -u2 "Could not move $legacy to the Trash; remove it by hand."
  fi
}

usage() {
  print "Usage: $0 <install|launch|status>"
  print ""
  print "  install  Build $prod_ref in an isolated worktree and install $app_path"
  print "  launch   Open the installed prod app"
  print "  status   Show the installed prod app's version and built commit"
}

validate_paths() {
  [[ $repository_root == /* && -f $repository_root/Package.swift ]] || {
    print -u2 "Could not resolve the Otto repository root."
    exit 2
  }
  [[ $app_path == /Applications/*.app || $app_path == $HOME/Applications/*.app ]] || {
    print -u2 "OTTO_PROD_APP_PATH must name an app inside /Applications or $HOME/Applications."
    exit 2
  }
  [[ $checkout_path == $HOME/Library/Caches/Otto/* \
    || $checkout_path == $HOME/Library/Caches/Muse/* ]] || {
    print -u2 "OTTO_PROD_CHECKOUT_PATH must remain inside $HOME/Library/Caches/Otto."
    exit 2
  }
  [[ $scratch_path == $HOME/Library/Caches/Otto/* \
    || $scratch_path == $HOME/Library/Caches/Muse/* ]] || {
    print -u2 "OTTO_PROD_SCRATCH_PATH must remain inside $HOME/Library/Caches/Otto."
    exit 2
  }
}

local_identity_hash() {
  local name hash
  for name in "$local_identity_name" "$legacy_identity_name"; do
    hash=$(
      /usr/bin/security find-certificate -a -c "$name" -Z \
        "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
        | /usr/bin/awk '/SHA-1 hash:/{print $3; exit}'
    )
    [[ -n $hash ]] && { print -r -- "$hash"; return; }
  done
}

signing_identity() {
  local configured_identity=${OTTO_PROD_CODESIGN_IDENTITY:-${MUSE_PROD_CODESIGN_IDENTITY:-}}
  if [[ -n $configured_identity ]]; then
    print -r -- "$configured_identity"
    return
  fi
  local identity
  identity=$(
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
      | /usr/bin/sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
      | /usr/bin/head -n 1
  )
  if [[ -n $identity ]]; then
    print -r -- "$identity"
    return
  fi
  identity=$(local_identity_hash)
  [[ -n $identity ]] || {
    print -u2 "No signing identity found. Run 'scripts/dev-app.sh install' once to create the"
    print -u2 "local identity, or set OTTO_PROD_CODESIGN_IDENTITY."
    exit 2
  }
  print -r -- "$identity"
}

refresh_checkout() {
  # Fast-forward local main from origin when possible (merges usually land on
  # GitHub). Best-effort: offline or diverged is fine, we build what we have.
  if [[ $(git -C "$repository_root" branch --show-current) != $prod_ref ]]; then
    git -C "$repository_root" fetch origin "$prod_ref:$prod_ref" 2>/dev/null \
      || print "Note: could not fast-forward '$prod_ref' from origin; building local '$prod_ref'."
  fi

  git -C "$repository_root" worktree remove --force "$checkout_path" 2>/dev/null || true
  /bin/rm -rf "$checkout_path"
  /bin/mkdir -p "${checkout_path:h}"
  git -C "$repository_root" worktree add --detach "$checkout_path" "$prod_ref" >/dev/null
  git -C "$repository_root" worktree prune
}

build_app() {
  if ! /bin/mkdir "$lock_directory" 2>/dev/null; then
    print -u2 "An Otto prod build is already running."
    return 75
  fi
  trap '/bin/rmdir "$lock_directory" 2>/dev/null || true' EXIT INT TERM

  refresh_checkout
  local built_commit
  built_commit=$(git -C "$checkout_path" rev-parse HEAD)
  print "Building Otto (prod) from $prod_ref @ ${built_commit[1,10]}…"

  local stage app_bundle binary_dir identity build_number
  stage=$(/usr/bin/mktemp -d /tmp/otto-prod-app.XXXXXX)
  app_bundle=$stage/Otto.app
  trap "/bin/rm -rf ${(q)stage}; /bin/rmdir ${(q)lock_directory} 2>/dev/null || true" \
    EXIT INT TERM

  /usr/bin/swift build \
    --package-path "$checkout_path" \
    --scratch-path "$scratch_path" \
    --jobs "${OTTO_PROD_BUILD_JOBS:-${MUSE_PROD_BUILD_JOBS:-4}}" \
    -c release
  binary_dir=$(
    /usr/bin/swift build \
      --package-path "$checkout_path" \
      --scratch-path "$scratch_path" \
      --jobs "${OTTO_PROD_BUILD_JOBS:-${MUSE_PROD_BUILD_JOBS:-4}}" \
      -c release \
      --show-bin-path
  )

  /bin/mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
  /usr/bin/install -m 755 "$binary_dir/Otto" "$app_bundle/Contents/MacOS/Otto"
  # Helper binaries vary by commit (e.g. otto-hermes-bridge landed after some
  # main snapshots); bundle whichever ones this checkout built.
  local helper
  for helper in ottoctl otto-mcp otto-hermes-bridge otto-openai-agent otto-hookd ottod; do
    [[ -f $binary_dir/$helper ]] \
      && /usr/bin/install -m 755 "$binary_dir/$helper" "$app_bundle/Contents/MacOS/$helper"
  done
  /usr/bin/install -m 644 "$checkout_path/packaging/Info.plist" \
    "$app_bundle/Contents/Info.plist"
  /usr/bin/install -m 644 "$checkout_path/packaging/THIRD_PARTY_NOTICES.md" \
    "$app_bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
  /usr/bin/install -m 644 "$checkout_path/packaging/AppIcon.icns" \
    "$app_bundle/Contents/Resources/AppIcon.icns"

  # Resource bundles also vary by commit (Otto_OttoApp.bundle only exists once
  # the OttoApp target declares resources); copy whichever ones were built.
  local resource_bundle
  for resource_bundle in "$binary_dir/SwiftTerm_SwiftTerm.bundle" \
    "$binary_dir/Otto_OttoApp.bundle" "$binary_dir/Otto_OttoServices.bundle"; do
    [[ -d $resource_bundle ]] || continue
    /usr/bin/ditto --norsrc "$resource_bundle" \
      "$app_bundle/Contents/Resources/${resource_bundle:t}"
  done

  build_number=$(git -C "$checkout_path" rev-list --count HEAD)
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$version" \
    "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleVersion -string "$build_number" \
    "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -insert OttoProductionCommit -string "$built_commit" \
    "$app_bundle/Contents/Info.plist"
  "$checkout_path/scripts/configure-private-phone" "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -lint "$app_bundle/Contents/Info.plist" >/dev/null
  /bin/chmod -R u+w "$app_bundle"
  /usr/bin/xattr -cr "$app_bundle"

  identity=$(signing_identity)
  print "Signing with $identity"
  local sign_options=(--force --sign "$identity" --timestamp=none)
  for helper in ottoctl otto-mcp otto-hermes-bridge otto-openai-agent otto-hookd ottod; do
    [[ -f $app_bundle/Contents/MacOS/$helper ]] \
      && /usr/bin/codesign "${sign_options[@]}" "$app_bundle/Contents/MacOS/$helper"
  done
  /usr/bin/codesign "${sign_options[@]}" \
    --entitlements "$checkout_path/packaging/Otto.entitlements" "$app_bundle"
  /usr/bin/codesign --verify --deep --strict --verbose=1 "$app_bundle"

  local install_directory install_candidate previous_app
  /bin/mkdir -p "${app_path:h}"
  install_directory=$(/usr/bin/mktemp -d "${app_path:h}/.otto-prod-install.XXXXXX")
  install_candidate=$install_directory/Otto.app
  previous_app=$install_directory/Previous\ Otto.app
  /usr/bin/ditto --norsrc "$app_bundle" "$install_candidate"
  /usr/bin/codesign --verify --deep --strict --verbose=1 "$install_candidate"
  quit_prod_app
  if [[ -d $app_path ]]; then
    /bin/mv "$app_path" "$previous_app"
  fi
  if ! /bin/mv "$install_candidate" "$app_path" \
    || ! /usr/bin/codesign --verify --deep --strict --verbose=1 "$app_path"
  then
    /bin/rm -rf "$app_path"
    if [[ -d $previous_app ]]; then
      /bin/mv "$previous_app" "$app_path"
    fi
    print -u2 "Otto installation failed; restored the previous application."
    exit 1
  fi
  /bin/rm -rf "$install_directory"
  /usr/bin/touch "$app_path"
  retire_legacy_app
  print "Installed $app_path ($prod_ref @ ${built_commit[1,10]}, build $build_number)"

  /bin/rm -rf "$stage"
  /bin/rmdir "$lock_directory" 2>/dev/null || true
  trap - EXIT INT TERM
}

quit_prod_app() {
  # Also quit a pre-rename Muse.app, which shares the data folder.
  /usr/bin/osascript -e 'tell application id "app.muse.desktop" to quit' \
    >/dev/null 2>&1 || true
  /usr/bin/osascript -e 'tell application id "io.openotto.desktop" to quit' \
    >/dev/null 2>&1 || true
  local deadline=$((SECONDS + 8))
  while /usr/bin/pgrep -f "$app_path/Contents/MacOS/Otto" >/dev/null 2>&1; do
    (( SECONDS >= deadline )) && break
    /bin/sleep 0.1
  done
}

launch_app() {
  [[ -d $app_path ]] || {
    print -u2 "$app_path is not installed. Run '$0 install' first."
    exit 2
  }
  local deadline=$((SECONDS + 8))
  while ! /usr/bin/open "$app_path" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      print -u2 "Otto could not be handed to macOS LaunchServices."
      exit 1
    fi
    /bin/sleep 0.2
  done
  while ! /usr/bin/pgrep -f "$app_path/Contents/MacOS/Otto" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      print -u2 "Otto launch was requested, but no running app process appeared."
      exit 1
    fi
    /bin/sleep 0.1
  done
  print "Opened $app_path"
}

show_status() {
  print "App: $app_path"
  if [[ -d $app_path ]]; then
    print "Bundle ID: $(/usr/bin/defaults read "$app_path/Contents/Info" CFBundleIdentifier)"
    print "Version: $(/usr/bin/defaults read "$app_path/Contents/Info" CFBundleShortVersionString)"
    print "Build: $(/usr/bin/defaults read "$app_path/Contents/Info" CFBundleVersion)"
    local commit
    commit=$(/usr/bin/defaults read "$app_path/Contents/Info" OttoProductionCommit 2>/dev/null \
      || /usr/bin/defaults read "$app_path/Contents/Info" MuseProductionCommit 2>/dev/null) \
      && print "Commit: $commit"
    /usr/bin/codesign -dv --verbose=2 "$app_path" 2>&1 \
      | /usr/bin/grep -E '^(Identifier|Authority|Signature|TeamIdentifier)=' || true
  else
    print "Installed: no"
  fi
  local head_commit
  head_commit=$(git -C "$repository_root" rev-parse "$prod_ref" 2>/dev/null) || return 0
  print "Latest $prod_ref: ${head_commit[1,10]}"
}

validate_paths
case ${1:-} in
  install) build_app ;;
  launch) launch_app ;;
  status) show_status ;;
  *) usage; exit 64 ;;
esac
