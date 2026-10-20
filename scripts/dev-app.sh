#!/bin/zsh
set -euo pipefail
setopt extendedglob

script_dir=${0:A:h}
invocation_root=${OTTO_DEV_REPOSITORY_PATH:-${MUSE_DEV_REPOSITORY_PATH:-${script_dir:h}}}
app_path=${OTTO_DEV_APP_PATH:-${MUSE_DEV_APP_PATH:-$HOME/Applications/Otto Dev.app}}
# Reuse an existing pre-rename build cache instead of forcing a cold build; the app itself
# moves ~/Library/Caches/Muse to ~/Library/Caches/Otto (leaving a symlink) on launch.
default_scratch_path=$HOME/Library/Caches/Otto/SwiftPM/macos-dev
if [[ ! -e $default_scratch_path && -d $HOME/Library/Caches/Muse/SwiftPM/macos-dev ]]; then
  default_scratch_path=$HOME/Library/Caches/Muse/SwiftPM/macos-dev
fi
scratch_path=${OTTO_DEV_SCRATCH_PATH:-${MUSE_DEV_SCRATCH_PATH:-$default_scratch_path}}
log_directory=$HOME/Library/Logs/Otto
lock_directory=${OTTO_DEV_LOCK_DIRECTORY:-${MUSE_DEV_LOCK_DIRECTORY:-/tmp/otto-dev-build-$UID.lock}}
local_identity_name="Otto Local Development"

# Builds from before the Otto rename installed "Muse Dev.app" (bundle app.muse.desktop.dev)
# beside the new app. Move the old copy to the Trash once the new one is in place; its data was
# already carried over by Otto Dev's launch migration.
retire_legacy_app() {
  local legacy="${app_path:h}/Muse Dev.app" identifier
  [[ $legacy != "$app_path" && -d $legacy ]] || return 0
  identifier=$(/usr/bin/defaults read "$legacy/Contents/Info" CFBundleIdentifier 2>/dev/null) \
    || return 0
  [[ $identifier == app.muse.desktop.dev ]] || return 0
  /bin/mkdir -p "$HOME/.Trash"
  if /bin/mv "$legacy" "$HOME/.Trash/Muse Dev $(/bin/date +%Y%m%d%H%M%S).app"; then
    print "Moved the pre-rename Muse Dev to the Trash: $legacy"
  else
    print -u2 "Could not move $legacy to the Trash; remove it by hand."
  fi
}

usage() {
  print "Usage: $0 <install|reload|launch|watch|status>"
}

canonical_repository_root() {
  local configured origin primary
  local canonical=${OTTO_DEV_CANONICAL_REPOSITORY_PATH:-${MUSE_DEV_CANONICAL_REPOSITORY_PATH:-}}
  if [[ -n $canonical ]]; then
    print -r -- "$canonical"
    return
  fi

  # otto.devRepositoryPath, or the pre-rename muse.devRepositoryPath.
  configured=$(
    /usr/bin/git -C "$invocation_root" config --get otto.devRepositoryPath 2>/dev/null \
      || /usr/bin/git -C "$invocation_root" config --get muse.devRepositoryPath 2>/dev/null \
      || true
  )
  if [[ -n $configured && -f $configured/Package.swift ]]; then
    print -r -- "${configured:A}"
    return
  fi

  # Otto's isolated agents may run in standalone local clones whose origin is the user's real
  # checkout. Follow that local origin so a worker can never silently make its clone the source
  # of the shared Otto Dev.app. Network origins are deliberately ignored.
  origin=$(
    /usr/bin/git -C "$invocation_root" remote get-url origin 2>/dev/null || true
  )
  if [[ $origin == file://* ]]; then origin=${origin#file://}; fi
  if [[ -n $origin && $origin != *://* ]]; then
    [[ $origin == /* ]] || origin=$invocation_root/$origin
    if [[ -f $origin/Package.swift ]]; then
      print -r -- "${origin:A}"
      return
    fi
  fi

  # Normal git worktrees share one repository. The first porcelain entry is the primary
  # checkout, which is the integration lane that owns the development app.
  primary=$(
    /usr/bin/git -C "$invocation_root" worktree list --porcelain 2>/dev/null \
      | /usr/bin/awk '/^worktree / {sub(/^worktree /, ""); print; exit}'
  )
  if [[ -n $primary && -f $primary/Package.swift ]]; then
    print -r -- "${primary:A}"
    return
  fi

  print -r -- "${invocation_root:A}"
}

repository_root=$(canonical_repository_root)

if [[ ${invocation_root:A} != $repository_root ]]; then
  print "Routing Otto Dev to canonical checkout: $repository_root"
  print "Changes in ${invocation_root:A} appear after they are integrated there."
fi

validate_paths() {
  [[ $repository_root == /* && -f $repository_root/Package.swift ]] || {
    print -u2 "Could not resolve the Otto repository root."
    exit 2
  }
  [[ $app_path == $HOME/Applications/*.app && $app_path != $HOME/Applications ]] || {
    print -u2 "OTTO_DEV_APP_PATH must name an app directly inside $HOME/Applications."
    exit 2
  }
  [[ $scratch_path == $repository_root/.build/* \
    || $scratch_path == $HOME/Library/Caches/Otto/* \
    || $scratch_path == $HOME/Library/Caches/Muse/* ]] || {
    print -u2 \
      "OTTO_DEV_SCRATCH_PATH must remain inside $repository_root/.build or $HOME/Library/Caches/Otto."
    exit 2
  }
}

local_identity_hash() {
  /usr/bin/security find-certificate -a -c "$local_identity_name" -Z \
    "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
    | /usr/bin/awk '/SHA-1 hash:/{print $3; exit}'
}

create_local_signing_identity() {
  local identity_directory certificate_path private_key_path identity_hash
  identity_directory=$(/usr/bin/mktemp -d /tmp/otto-local-signing.XXXXXX)
  certificate_path=$identity_directory/certificate.pem
  private_key_path=$identity_directory/private-key.pem

  {
    print "Creating persistent Otto Dev signing identity…" >&2
    /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -subj "/CN=$local_identity_name/O=Otto Development" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" \
      -keyout "$private_key_path" -out "$certificate_path" >/dev/null 2>&1
    /usr/bin/security import "$certificate_path" \
      -k "$HOME/Library/Keychains/login.keychain-db" >/dev/null
    /usr/bin/security import "$private_key_path" \
      -k "$HOME/Library/Keychains/login.keychain-db" \
      -T /usr/bin/codesign >/dev/null
  } always {
    /bin/rm -rf "$identity_directory"
  }

  identity_hash=$(local_identity_hash)
  [[ -n $identity_hash ]] || {
    print -u2 "Could not create the Otto Dev signing identity."
    return 1
  }
  print -r -- "$identity_hash"
}

signing_identity() {
  local configured_identity=${OTTO_DEV_CODESIGN_IDENTITY:-${MUSE_DEV_CODESIGN_IDENTITY:-}}
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
  if [[ -z $identity ]]; then
    identity=$(create_local_signing_identity)
  fi
  print -r -- "$identity"
}

build_app() {
  if ! /bin/mkdir "$lock_directory" 2>/dev/null; then
    print -u2 "An Otto Dev build is already running."
    return 75
  fi
  trap '/bin/rmdir "$lock_directory" 2>/dev/null || true' EXIT INT TERM

  local stage app_bundle binary_dir identity build_number
  /bin/mkdir -p "${scratch_path:h}"
  stage=$(/usr/bin/mktemp -d /tmp/otto-dev-app.XXXXXX)
  app_bundle=$stage/Otto\ Dev.app
  trap "/bin/rm -rf ${(q)stage}; /bin/rmdir ${(q)lock_directory} 2>/dev/null || true" \
    EXIT INT TERM

  print "Building Otto Dev…"
  local build_attempt=1
  while ! /usr/bin/swift build \
    --package-path "$repository_root" \
    --scratch-path "$scratch_path" \
    --disable-automatic-resolution \
    --jobs "${OTTO_DEV_BUILD_JOBS:-${MUSE_DEV_BUILD_JOBS:-4}}" \
    -c debug
  do
    if (( build_attempt >= 3 )); then
      print -u2 "Otto Dev did not build after $build_attempt attempts."
      exit 1
    fi
    build_attempt=$((build_attempt + 1))
    print -u2 "Sources changed or the build was interrupted; retrying ($build_attempt/3)…"
    /bin/sleep 1
  done
  binary_dir=$(
    /usr/bin/swift build \
    --package-path "$repository_root" \
    --scratch-path "$scratch_path" \
    --disable-automatic-resolution \
    --jobs "${OTTO_DEV_BUILD_JOBS:-${MUSE_DEV_BUILD_JOBS:-4}}" \
    -c debug \
      --show-bin-path
  )

  /bin/mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
  /usr/bin/install -m 755 "$binary_dir/Otto" "$app_bundle/Contents/MacOS/Otto"
  /usr/bin/install -m 755 "$binary_dir/ottoctl" "$app_bundle/Contents/MacOS/ottoctl"
  /usr/bin/install -m 755 "$binary_dir/otto-mcp" "$app_bundle/Contents/MacOS/otto-mcp"
  /usr/bin/install -m 755 "$binary_dir/otto-hermes-bridge" "$app_bundle/Contents/MacOS/otto-hermes-bridge"
  /usr/bin/install -m 755 "$binary_dir/otto-openai-agent" "$app_bundle/Contents/MacOS/otto-openai-agent"
  /usr/bin/install -m 755 "$binary_dir/otto-hookd" "$app_bundle/Contents/MacOS/otto-hookd"
  /usr/bin/install -m 755 "$binary_dir/ottod" "$app_bundle/Contents/MacOS/ottod"
  /usr/bin/install -m 644 "$repository_root/packaging/Info.dev.plist" \
    "$app_bundle/Contents/Info.plist"
  /usr/bin/install -m 644 "$repository_root/packaging/THIRD_PARTY_NOTICES.md" \
    "$app_bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
  /usr/bin/install -m 644 "$repository_root/packaging/AppIcon.icns" \
    "$app_bundle/Contents/Resources/AppIcon.icns"

  local resource_bundle
  for resource_bundle in "$binary_dir/SwiftTerm_SwiftTerm.bundle" \
    "$binary_dir/Otto_OttoApp.bundle" "$binary_dir/Otto_OttoServices.bundle"; do
    [[ -d $resource_bundle ]] || {
      print -u2 "Missing resource bundle: $resource_bundle"
      exit 2
    }
    /usr/bin/ditto --norsrc "$resource_bundle" \
      "$app_bundle/Contents/Resources/${resource_bundle:t}"
  done

  build_number=$(/usr/bin/git -C "$repository_root" rev-list --count HEAD)
  /usr/bin/plutil -replace CFBundleVersion -string "$build_number" \
    "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -insert OttoDevelopmentAutoReload -bool true \
    "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -insert OttoDevelopmentRepositoryPath -string "$repository_root" \
    "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -insert OttoDevelopmentScratchPath -string "$scratch_path" \
    "$app_bundle/Contents/Info.plist"
  "$repository_root/scripts/configure-private-phone" "$app_bundle/Contents/Info.plist"
  "$repository_root/scripts/configure-google-app-client" "$app_bundle/Contents/Info.plist"
  /usr/bin/plutil -lint "$app_bundle/Contents/Info.plist" >/dev/null
  /bin/chmod -R u+w "$app_bundle"
  /usr/bin/xattr -cr "$app_bundle"

  identity=$(signing_identity)
  print "Signing with $identity"
  local sign_options=(--force --sign "$identity" --timestamp=none)
  local app_sign_options=(--force --sign "$identity" --timestamp=none)
  /usr/bin/codesign "${sign_options[@]}" "$app_bundle/Contents/MacOS/ottoctl"
  /usr/bin/codesign "${sign_options[@]}" "$app_bundle/Contents/MacOS/otto-mcp"
  /usr/bin/codesign "${sign_options[@]}" "$app_bundle/Contents/MacOS/otto-hermes-bridge"
  /usr/bin/codesign "${sign_options[@]}" "$app_bundle/Contents/MacOS/otto-openai-agent"
  /usr/bin/codesign "${sign_options[@]}" "$app_bundle/Contents/MacOS/otto-hookd"
  /usr/bin/codesign "${sign_options[@]}" "$app_bundle/Contents/MacOS/ottod"
  /usr/bin/codesign "${app_sign_options[@]}" \
    --entitlements "$repository_root/packaging/Otto.entitlements" "$app_bundle"
  /usr/bin/codesign --verify --deep --strict --verbose=1 "$app_bundle"

  local install_directory install_candidate previous_app
  /bin/mkdir -p "$HOME/Applications"
  install_directory=$(/usr/bin/mktemp -d "$HOME/Applications/.otto-dev-install.XXXXXX")
  install_candidate=$install_directory/Otto\ Dev.app
  previous_app=$install_directory/Previous\ Otto\ Dev.app
  /usr/bin/ditto --norsrc "$app_bundle" "$install_candidate"
  /usr/bin/codesign --verify --deep --strict --verbose=1 "$install_candidate"
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
    print -u2 "Otto Dev installation failed; restored the previous application."
    exit 1
  fi
  /bin/rm -rf "$install_directory"
  /usr/bin/touch "$app_path"
  retire_legacy_app
  print "Installed $app_path"

  /bin/rm -rf "$stage"
  /bin/rmdir "$lock_directory" 2>/dev/null || true
  trap - EXIT INT TERM
}

quit_dev_app() {
  /usr/bin/osascript -e 'tell application id "io.openotto.desktop.dev" to quit' \
    >/dev/null 2>&1 || true
  # Otto Dev builds from before the bundle identifier changed.
  /usr/bin/osascript -e 'tell application id "app.muse.desktop.dev" to quit' \
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
      print -u2 "Otto Dev could not be handed to macOS LaunchServices."
      exit 1
    fi
    /bin/sleep 0.2
  done
  while ! /usr/bin/pgrep -f "$app_path/Contents/MacOS/Otto" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      print -u2 "Otto Dev launch was requested, but no running app process appeared."
      exit 1
    fi
    /bin/sleep 0.1
  done
  print "Opened $app_path"
}

reload_app() {
  build_app
  quit_dev_app
  launch_app
}

source_fingerprint() {
  (
    cd "$repository_root"
    /usr/bin/find Sources Tests packaging Package.swift -type f \
      \( -name '*.swift' -o -name '*.plist' -o -name '*.entitlements' -o -name 'Package.swift' \) \
      -print0 \
      | /usr/bin/xargs -0 /usr/bin/stat -f '%m:%z:%N' \
      | /usr/bin/shasum -a 256 \
      | /usr/bin/awk '{print $1}'
  )
}

watch_sources() {
  local previous current
  previous=$(source_fingerprint)
  print "Watching Otto sources. Log: $log_directory/dev-reloader.log"
  while true; do
    /bin/sleep 1
    current=$(source_fingerprint)
    [[ $current == $previous ]] && continue
    previous=$current
    /bin/sleep 0.8
    current=$(source_fingerprint)
    previous=$current
    print "Change detected at $(/bin/date '+%H:%M:%S'); rebuilding…"
    reload_app || print -u2 "Otto Dev reload failed; continuing to watch."
  done
}

show_status() {
  print "App: $app_path"
  print "Canonical source: $repository_root"
  if [[ -d $app_path ]]; then
    print "Bundle ID: $(/usr/bin/defaults read "$app_path/Contents/Info" CFBundleIdentifier)"
    print "Version: $(/usr/bin/defaults read "$app_path/Contents/Info" CFBundleShortVersionString)"
    local installed_source
    installed_source=$(
      /usr/bin/defaults read "$app_path/Contents/Info" OttoDevelopmentRepositoryPath \
        2>/dev/null \
        || /usr/bin/defaults read "$app_path/Contents/Info" MuseDevelopmentRepositoryPath \
          2>/dev/null \
        || true
    )
    print "Installed source: ${installed_source:-unknown}"
    if [[ -n $installed_source && ${installed_source:A} != $repository_root ]]; then
      print -u2 "Source drift: run '$repository_root/scripts/dev-app.sh reload' to repair it."
    fi
    /usr/bin/codesign -dv --verbose=2 "$app_path" 2>&1 \
      | /usr/bin/grep -E '^(Identifier|Authority|Signature|TeamIdentifier)=' || true
  else
    print "Installed: no"
  fi
  print "Auto reload: built into Otto Dev"
}

validate_paths
case ${1:-} in
  install) build_app ;;
  reload) reload_app ;;
  launch) launch_app ;;
  watch) watch_sources ;;
  status) show_status ;;
  *) usage; exit 64 ;;
esac
