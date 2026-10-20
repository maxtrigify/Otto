#!/bin/zsh
set -euo pipefail
setopt extendedglob

if (( $# != 3 )); then
  print -u2 "Usage: $0 <ssh-host> <remote-socket> <local-socket>"
  exit 64
fi
host=$1
remote_socket=$2
local_socket=$3
[[ $host != -* && $host == [A-Za-z0-9_.@:-]## ]] || exit 64
[[ $remote_socket == /* && $local_socket == /* ]] || exit 64
[[ $remote_socket != *:* && $local_socket != *:* ]] || exit 64

local_parent=${local_socket:h}
if [[ -e $local_parent ]]; then
  [[ -d $local_parent && ! -L $local_parent && -O $local_parent ]] || {
    print -u2 "Local socket parent must be an owned, non-symlink directory."
    exit 73
  }
  local_mode=$(/usr/bin/stat -f '%Lp' "$local_parent")
  (( (8#$local_mode & 8#077) == 0 )) || {
    print -u2 "Local socket parent must not be accessible by group or other users."
    exit 77
  }
else
  /bin/mkdir -m 700 -p "$local_parent"
fi
# Hosts that have not been upgraded since the rename still serve `mused.sock` beside the
# `ottod.sock` path the Mac now asks for. Prefer ottod.sock; fall back to mused.sock.
if [[ ${remote_socket:t} == ottod.sock || ${remote_socket:t} == ottod-<->.sock ]]; then
  legacy_socket=${remote_socket:h}/${${remote_socket:t}/ottod/mused}
  remote_socket_q=${(q)remote_socket}
  legacy_socket_q=${(q)legacy_socket}
  if ! ssh -- "$host" "test -S $remote_socket_q" && ssh -- "$host" "test -S $legacy_socket_q"; then
    print -u2 "Remote ottod socket not found; using the pre-rename mused socket $legacy_socket."
    remote_socket=$legacy_socket
  fi
fi
/bin/rm -f "$local_socket"
exec ssh -N -o ExitOnForwardFailure=yes -L "$local_socket:$remote_socket" -- "$host"
