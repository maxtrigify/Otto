#!/bin/zsh
set -euo pipefail
setopt extendedglob

if (( $# != 3 )); then
  print -u2 "Usage: $0 <ssh-host> <remote-workspace> <local-token-output>"
  exit 64
fi

host=$1
remote_workspace=$2
local_token_output=$3
[[ $host != -* && $host == [A-Za-z0-9_.@:-]## ]] || {
  print -u2 "SSH host contains unsupported characters"
  exit 64
}
[[ $remote_workspace == /* ]] || {
  print -u2 "Remote workspace must be an absolute path"
  exit 64
}

script_dir=${0:A:h}
repository_root=${script_dir:h}
swift build --package-path "$repository_root" -c release --product ottod -Xswiftc -warnings-as-errors
binary_dir=$(swift build --package-path "$repository_root" -c release --show-bin-path)
stage=$(mktemp -d /tmp/otto-ottod-bootstrap.XXXXXX)
trap '/bin/rm -rf "$stage"' EXIT

/usr/bin/openssl rand -hex 32 > "$stage/token"
/bin/chmod 600 "$stage/token"
remote_home=$(ssh -- "$host" 'printf %s "$HOME"')
remote_uid=$(ssh -- "$host" 'id -u')
[[ $remote_home == /* && $remote_uid == <-> ]] || {
  print -u2 "Remote host did not return a valid home directory and user ID"
  exit 1
}
remote_state=$remote_home/.local/share/otto
remote_socket=/tmp/ottod-$remote_uid.sock
remote_binary=$remote_home/.local/bin/ottod
remote_token=$remote_home/.config/otto/remote-token
label=io.openotto.ottod
remote_plist=$remote_home/Library/LaunchAgents/$label.plist

plist=$stage/$label.plist
/usr/bin/plutil -create xml1 "$plist"
/usr/bin/plutil -insert Label -string $label "$plist"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$remote_binary" "$plist"
/usr/bin/plutil -insert ProgramArguments.1 -string serve "$plist"
/usr/bin/plutil -insert ProgramArguments.2 -string --token-file "$plist"
/usr/bin/plutil -insert ProgramArguments.3 -string "$remote_token" "$plist"
/usr/bin/plutil -insert ProgramArguments.4 -string --state-dir "$plist"
/usr/bin/plutil -insert ProgramArguments.5 -string "$remote_state" "$plist"
/usr/bin/plutil -insert ProgramArguments.6 -string --workspace "$plist"
/usr/bin/plutil -insert ProgramArguments.7 -string "$remote_workspace" "$plist"
/usr/bin/plutil -insert ProgramArguments.8 -string --socket "$plist"
/usr/bin/plutil -insert ProgramArguments.9 -string "$remote_socket" "$plist"
/usr/bin/plutil -insert RunAtLoad -bool true "$plist"
/usr/bin/plutil -insert KeepAlive -bool true "$plist"

scp -- "$binary_dir/ottod" "$host:/tmp/ottod.install"
scp -- "$stage/token" "$host:/tmp/ottod.token.install"
scp -- "$plist" "$host:/tmp/ottod.plist.install"
scp -- "$script_dir/ottod-remote-migrate.sh" "$host:/tmp/ottod-remote-migrate.sh"

remote_home_q=${(q)remote_home}
remote_binary_q=${(q)remote_binary}
remote_token_q=${(q)remote_token}
remote_plist_q=${(q)remote_plist}
# The migration step retires a pre-rename `mused` LaunchAgent and moves ~/.config/muse and
# ~/.local/share/muse to their Otto names (only when the new ones are absent, leaving symlinks).
ssh -- "$host" "/bin/sh /tmp/ottod-remote-migrate.sh $remote_home_q $remote_uid && rm /tmp/ottod-remote-migrate.sh && mkdir -p $remote_home_q/.local/bin $remote_home_q/.local/share/otto $remote_home_q/.config/otto $remote_home_q/Library/LaunchAgents && chmod 700 $remote_home_q/.local/share/otto $remote_home_q/.config/otto && install -m 755 /tmp/ottod.install $remote_binary_q && install -m 600 /tmp/ottod.token.install $remote_token_q && install -m 600 /tmp/ottod.plist.install $remote_plist_q && rm /tmp/ottod.install /tmp/ottod.token.install /tmp/ottod.plist.install && (launchctl bootout gui/$remote_uid/$label >/dev/null 2>&1 || true) && launchctl bootstrap gui/$remote_uid $remote_plist_q && ( [ -e $remote_home_q/.local/bin/mused ] || [ -L $remote_home_q/.local/bin/mused ] || ln -s $remote_binary_q $remote_home_q/.local/bin/mused )"

/bin/mkdir -p "${local_token_output:h}"
/usr/bin/install -m 600 "$stage/token" "$local_token_output"
print "Installed ottod on $host"
print "Remote socket: $remote_socket"
print "Local token: $local_token_output"
