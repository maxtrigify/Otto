# Remote agents

`ottod` is a user-level remote process supervisor (named `mused` before the Muse → Otto rename). It keeps PTYs and an append-only event journal alive independently of any one Mac client connection. Local Otto owns canvas layout; `ottod` owns remote process state. Reconnect requests events after the last acknowledged monotonically increasing cursor.

The initial transport is a private Unix socket forwarded through SSH. There is no public inbound Otto port. Requests are independently authenticated with a 256-bit token stored in an owner-only file.

## Local development

```sh
swift build -c release --product ottod
.build/release/ottod serve \
  --token-file /owner-only/token \
  --state-dir /owner-only/state \
  --workspace /absolute/workspace \
  --socket /tmp/ottod-$UID.sock
```

`scripts/bootstrap-ottod-macos.sh` installs the release binary, token, and a per-user LaunchAgent (`io.openotto.ottod`) on a remote macOS host. `scripts/tunnel-ottod.sh` creates the Unix-socket SSH forward; when asked for an `ottod.sock` path that does not exist on the host it falls back to the pre-rename `mused.sock` beside it, so the Mac can still reach a host that has not been upgraded. The old `*-mused-*` script names remain as thin wrappers. Host-key verification remains OpenSSH's responsibility and must never be bypassed.
The tunnel socket must live in an owner-only directory owned by the current user. The helper creates
that directory with mode `0700` when absent, but refuses to chmod an existing directory or accept a
symlink/shared parent such as `/tmp`.

## Linux VPS package

The Linux build uses the same authenticated protocol and a `posix_spawn` PTY backend with a real
session/controlling terminal. On an Ubuntu runner, `scripts/package-ottod-linux.sh` creates a
versioned `ottod-<version>-linux-<arch>.tar.gz` plus SHA-256 containing `ottod`, a hardened
user-level systemd unit, and the installer. Extract it on the VPS and run:

```sh
./install-ottod-linux.sh /absolute/workspace
```

The installer creates an owner-only 256-bit token, configuration (`~/.config/otto`, including
`ottod.env`), and state (`~/.local/share/otto`) directories under the remote user's home, installs
the daemon as `~/.local/bin/ottod`, and enables `ottod.service` in the user's systemd manager. It
never opens a TCP port; tunnel `%t/ottod.sock` over SSH. The user manager must be
running, and long-lived service after logout may require the VPS administrator to enable linger for
that user.

Current protocol operations cover hello/reconnect, heartbeat/resource metrics, event paging, PTY launch/input/resize/stop, and bounded atomic file transfer. Remote output is stored in the remote journal because replay is an explicit feature; it is never included in local diagnostics or telemetry.

The connection sheet stores only the forwarded socket path in application preferences. Its token is stored in Keychain. Rotation first replaces the remote owner-only token file atomically, immediately invalidates the old token, and then updates Keychain after the remote acknowledgement. Fleet retains the last known sessions while explicitly showing `REMOTE`, `RECONNECTING`, or `OFFLINE`.

## Migrating a `mused` host

Hosts installed before the rename run `mused` with `~/.config/muse` and `~/.local/share/muse`. Running
the new installer (`install-ottod-linux.sh`) or `bootstrap-ottod-macos.sh` against such a host
migrates it automatically and never deletes data:

1. The old `mused.service` is stopped and disabled (Linux) or the `app.muse.mused` LaunchAgent is
   booted out (macOS). The old unit/plist is renamed with a `.disabled` suffix, not removed.
2. `~/.config/muse` → `~/.config/otto` and `~/.local/share/muse` → `~/.local/share/otto` are renamed
   only when the new directory does not exist yet, and a symlink is left at the old path. When both
   exist nothing is touched and the Otto directory is used. `mused.env` is copied to `ottod.env`
   (the original is kept); the token file is reused, so the Mac's stored token keeps working.
3. `ottod` is installed and `~/.local/bin/mused` becomes a compatibility symlink to it. A regular
   `mused` file is replaced only when it is the old daemon, and is kept beside it as
   `mused.previous-<timestamp>`; anything else at that path is left alone.

Every step logs to stderr and re-running the installer is a no-op for the migration. The socket
moves from `mused.sock` to `ottod.sock`; reconnect from the Mac with the new path (the tunnel helper
falls back to `mused.sock` for hosts that have not been migrated yet).

## Signed upgrades

Daemon releases use an Ed25519-signed immutable manifest containing the exact version, monotonically
increasing build, platform, protocol version, SHA-256, byte count, and generation time. Produce one
from the artifact itself so the hash and size are not copied by hand:

```sh
OTTO_SIGNING_PRIVATE_KEY=<base64-private-key> \
OTTO_SIGNING_KEY_ID=<key-id> \
  otto-release sign-remote-artifact ottod 0.2.0 2 linux-arm64 signed-upgrade.json
```

The updater rejects unknown signing keys, tampering, incompatible platforms/protocols, and any
downgrade or same-build reinstall. On every platform it re-verifies the exact SHA-256 and size after
staging and after installation. macOS additionally verifies the candidate's code signature before
and after an atomic swap. Linux creates a same-directory hard-link rollback before atomically
renaming the staged inode over the destination. Both paths keep one `<name>.previous` artifact and
restore it if post-install validation fails. The destination may be named `ottod` or, on hosts not
yet migrated, `mused`. The public verification key is non-secret and must be
obtained from the trusted Otto release configuration; never accept a key supplied by the remote host
being upgraded.

```sh
ottod install-upgrade \
  --manifest signed-upgrade.json --artifact ./ottod --destination "$HOME/.local/bin/ottod" \
  --current-version 0.1.0 --current-build 1 \
  --key-id <trusted-key-id> --public-key <trusted-base64-public-key>
```

Restart the per-user LaunchAgent or systemd unit only after the command returns its JSON receipt.
Supported manifest platforms are `macos-arm64`, `macos-x86_64`, `linux-arm64`, and `linux-x86_64`.
The Linux branch cross-compiles for x86_64 and ARM64 with Swift 6.2.4's official Static Linux SDK,
and the static ARM64 daemon now passes on an Ubuntu 26.04 ARM64 kernel. The native gate covers the
complete authenticated protocol, real PTY launch/input/resize/stop, cursor replay, file transfer,
token revocation, signed install/rollback, and packaged user-systemd install/restart. A real two-Mac
SSH tunnel gate separately proves those protocol operations across machines. Rendered Fleet
integration proof and a two-machine Linux build/install/reconnect exercise remain incomplete and
are tracked in the execution-plan audit.
