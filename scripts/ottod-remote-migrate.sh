#!/bin/sh
# Runs on a remote macOS host before ottod is installed. Retires the pre-rename `mused`
# LaunchAgent and moves its folders to the Otto names. Never deletes data and is a no-op when
# run again: a folder is moved only when its new name is free, and a symlink is left behind.
set -eu

home=$1
uid=$2
log() { printf 'ottod migrate: %s\n' "$*" >&2; }

legacy_label=app.muse.mused
legacy_plist=$home/Library/LaunchAgents/$legacy_label.plist
if launchctl print "gui/$uid/$legacy_label" >/dev/null 2>&1; then
  launchctl bootout "gui/$uid/$legacy_label" >/dev/null 2>&1 || true
  log "stopped the $legacy_label LaunchAgent"
fi
if [ -f "$legacy_plist" ]; then
  mv "$legacy_plist" "$legacy_plist.disabled"
  log "disabled $legacy_plist (renamed to .disabled)"
fi

migrate_directory() {
  legacy=$1
  current=$2
  [ -L "$legacy" ] && return 0
  [ -d "$legacy" ] || return 0
  if [ -e "$current" ] || [ -L "$current" ]; then
    log "both $legacy and $current exist; leaving both untouched and using $current"
    return 0
  fi
  mkdir -p "$(dirname "$current")"
  mv "$legacy" "$current"
  ln -s "$current" "$legacy"
  log "moved $legacy to $current (symlink left at the old path)"
}
migrate_directory "$home/.config/muse" "$home/.config/otto"
migrate_directory "$home/.local/share/muse" "$home/.local/share/otto"

binary_dir=$home/.local/bin
if [ -f "$binary_dir/mused" ] && [ ! -L "$binary_dir/mused" ]; then
  if grep -a -q 'install-upgrade' "$binary_dir/mused" && grep -a -q 'token-file' "$binary_dir/mused"; then
    mv "$binary_dir/mused" "$binary_dir/mused.previous-$(date +%Y%m%d%H%M%S)"
    ln -s "$binary_dir/ottod" "$binary_dir/mused"
    log "replaced the old mused binary with a symlink to ottod (backup kept beside it)"
  else
    log "left $binary_dir/mused alone: it does not look like the Otto daemon"
  fi
fi
