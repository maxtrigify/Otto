#!/usr/bin/env bash
set -euo pipefail

# Installs (or upgrades) ottod for the current user. Hosts set up before the Muse → Otto rename
# ran `mused` from ~/.local/bin with ~/.config/muse and ~/.local/share/muse; those are migrated
# here without deleting anything, and re-running the installer is a no-op for the migration.

usage='Usage: install-ottod-linux.sh <absolute-workspace-path>'
if [[ ${OTTO_INSTALL_ALLOW_ANY_OS:-0} != 1 && $(uname -s) != Linux ]] \
  || [[ $# -ne 1 || $1 != /* || ! -d $1 ]]; then
  printf '%s\n' "$usage" >&2
  exit 64
fi
if ! command -v systemctl >/dev/null || ! command -v openssl >/dev/null; then
  printf 'systemd and openssl are required.\n' >&2
  exit 69
fi

log() { printf 'ottod install: %s\n' "$*" >&2; }

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
workspace=$(realpath "$1")
binary_dir="$HOME/.local/bin"
state_dir="$HOME/.local/share/otto"
config_dir="$HOME/.config/otto"
unit_dir="$HOME/.config/systemd/user"
legacy_state_dir="$HOME/.local/share/muse"
legacy_config_dir="$HOME/.config/muse"

# Moves a pre-rename directory to its new name only when the new name is free, then leaves a
# symlink at the old name so an old daemon (or anything else) that still uses it keeps working.
migrate_directory() {
  local legacy=$1 current=$2
  if [[ -L $legacy ]]; then
    return 0
  fi
  if [[ ! -d $legacy ]]; then
    return 0
  fi
  if [[ -e $current || -L $current ]]; then
    log "both $legacy and $current exist; leaving both untouched and using $current"
    return 0
  fi
  install -d -m 700 "$(dirname "$current")"
  mv -- "$legacy" "$current"
  ln -s -- "$current" "$legacy"
  log "moved $legacy to $current (symlink left at the old path)"
}

# 1. Stop the pre-rename service so it releases its socket and state before anything moves.
if systemctl --user cat mused.service >/dev/null 2>&1; then
  if systemctl --user is-enabled --quiet mused.service 2>/dev/null \
    || systemctl --user is-active --quiet mused.service 2>/dev/null; then
    systemctl --user disable --now mused.service >/dev/null 2>&1 || true
    log "stopped and disabled mused.service"
  fi
fi

# 2. Configuration and state directories.
migrate_directory "$legacy_config_dir" "$config_dir"
migrate_directory "$legacy_state_dir" "$state_dir"
install -d -m 700 "$binary_dir" "$state_dir" "$config_dir" "$unit_dir"
if [[ -f $config_dir/mused.env && ! -e $config_dir/ottod.env ]]; then
  cp -p -- "$config_dir/mused.env" "$config_dir/ottod.env"
  log "copied mused.env to ottod.env (original kept)"
fi

# 3. Binary and unit.
install -m 755 "$script_dir/ottod" "$binary_dir/ottod"
install -m 600 "$script_dir/ottod.service" "$unit_dir/ottod.service"
if [[ -L $binary_dir/mused ]]; then
  if [[ $(readlink -- "$binary_dir/mused") != "$binary_dir/ottod" ]]; then
    ln -sfn -- "$binary_dir/ottod" "$binary_dir/mused"
    log "pointed the mused compatibility symlink at ottod"
  fi
elif [[ -f $binary_dir/mused ]]; then
  # Only replace the file if it is the old daemon itself; never clobber something unrelated.
  if grep -a -q 'install-upgrade' "$binary_dir/mused" \
    && grep -a -q 'token-file' "$binary_dir/mused"; then
    mv -- "$binary_dir/mused" "$binary_dir/mused.previous-$(date +%Y%m%d%H%M%S)"
    ln -s -- "$binary_dir/ottod" "$binary_dir/mused"
    log "replaced the old mused binary with a symlink to ottod (backup kept beside it)"
  else
    log "left $binary_dir/mused alone: it does not look like the Otto daemon"
  fi
elif [[ ! -e $binary_dir/mused ]]; then
  ln -s -- "$binary_dir/ottod" "$binary_dir/mused"
  log "created mused compatibility symlink"
fi

# 4. Token and environment.
if [[ ! -f $config_dir/token ]]; then
  umask 077
  openssl rand -hex 32 >"$config_dir/token"
fi
chmod 600 "$config_dir/token"
printf 'OTTO_WORKSPACE=%q\n' "$workspace" >"$config_dir/ottod.env"
chmod 600 "$config_dir/ottod.env"

# 5. Retire the old unit file (disabled above); the new unit supersedes it.
if [[ -f $unit_dir/mused.service && ! -L $unit_dir/mused.service ]]; then
  mv -- "$unit_dir/mused.service" "$unit_dir/mused.service.disabled"
  log "renamed the old unit to mused.service.disabled"
fi

systemctl --user daemon-reload
systemctl --user enable --now ottod.service
systemctl --user restart ottod.service
socket_path="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ottod.sock"
for _ in $(seq 1 100); do
  if systemctl --user is-active --quiet ottod.service && [[ -S $socket_path ]]; then
    break
  fi
  sleep 0.05
done
if ! systemctl --user is-active --quiet ottod.service || [[ ! -S $socket_path ]]; then
  systemctl --user --no-pager --full status ottod.service >&2 || true
  printf 'ottod did not create its private socket: %s\n' "$socket_path" >&2
  exit 70
fi
systemctl --user --no-pager --full status ottod.service
printf 'Installed ottod for %s. Socket: %s\n' "$workspace" "$socket_path"
