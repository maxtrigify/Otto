# Releasing Otto

Otto is distributed directly as a hardened-runtime Developer ID application. The Mac App Store sandbox is not used because user-authorised CLI and PTY execution is core behavior.

## Public release (one command)

Public distribution runs through the `maxtrigify/muse-releases` repository: GitHub Releases host the zip, GitHub Pages hosts the download site and the signed update manifest the app polls (`v1/updates/manifest`).

1. Add a `## <version> — <date>` section to `CHANGELOG.md`. It becomes the in-app update notes and the site changelog verbatim.
2. Run `scripts/publish-release.sh <version> <build-number>` with a monotonically increasing build number.

The script packages and verifies the app, notarizes when `OTTO_NOTARY_PROFILE` is set (otherwise it publishes an ad-hoc signed build that needs right-click → Open on first launch), signs the update manifest with the Ed25519 release key stored in the login Keychain (service `otto-release-signing`, falling back to the pre-rename `muse-release-signing`; key ID `muse-2026-1`, which keeps its name because every installed updater trusts it), uploads the zip to a GitHub release, and pushes the manifest plus `updates.json`/`changelog.json` to the site. Installed apps notice the new manifest within six hours (or on launch / “Check for Updates…”), show the changelog, and offer Download & Restart. The matching public key is embedded in `Sources/OttoApp/AppUpdateController.swift`; keep old key IDs trusted there while clients may still verify manifests signed by them.

## Local artifact

Run `scripts/package-macos.sh`, then `scripts/verify-release.sh`. Without `OTTO_CODESIGN_IDENTITY`, this creates and verifies an ad-hoc signed development ZIP under `.build/distribution`. Bundle assembly and verification occur in clean temporary staging so File Provider metadata from synced workspaces cannot contaminate the signature. The artifact is suitable for CI and local install testing, but not for customers.

## Candidate artifact

Set these variables in the release environment:

- `OTTO_VERSION` and monotonically increasing `OTTO_BUILD_NUMBER`.
- `OTTO_CODESIGN_IDENTITY` to a Developer ID Application identity.
- `OTTO_NOTARY_PROFILE` to a `notarytool` Keychain profile containing App Store Connect credentials.

The pre-rename `MUSE_*` names are still read when the `OTTO_*` one is unset.

Run:

```sh
scripts/package-macos.sh
scripts/verify-release.sh
scripts/notarize-macos.sh
```

After notarisation, publish the ZIP to the CDN and produce a signed update manifest containing its exact SHA-256 and byte count. Promote internal to beta, perform the health check, then promote the same immutable artifact to stable. Never rebuild between channels.

Sign a reviewed manifest with `otto-release sign-manifest manifest.json signed-manifest.json`. The Ed25519 private key is read only from `OTTO_SIGNING_PRIVATE_KEY` (or the pre-rename `MUSE_SIGNING_PRIVATE_KEY`); `otto-release public-key` prints the corresponding public key for application configuration. Keep old public keys embedded while clients may still hold documents signed by them.

For a remote daemon candidate, prefer `otto-release sign-remote-artifact <ottod> <version> <build> <macos-arm64|macos-x86_64|linux-arm64|linux-x86_64> <signed-upgrade.json>`. This derives SHA-256 and byte count from the exact file. Distribute the artifact and signed document as one immutable pair. The client must supply the already-configured public release key to the remote installer; a key reported by the remote host is not a trust anchor.

## Muse → Otto migration release

The first Otto release goes to people running Muse 0.1.59 (bundle `app.muse.desktop`, usually at `/Applications/Muse.app`). No bridge release is needed; this section records why and the exact order.

### What Muse 0.1.59 does with an Otto build

Evidence is from the 0.1.59 tree (`git show 3480405:<path>`):

- `Sources/MuseApp/AppUpdateController.swift:54` — automatic checks run only when the running bundle is `app.muse.desktop`. That is the installed Muse, so it keeps polling.
- `:110` and `Sources/MuseCommercial/UpdateManager.swift:41-60` — the only trust checks are the Ed25519 manifest signature (key `muse-2026-1`), `blockedVersions`, the rollout bucket, the minimum macOS version, and a strictly newer version or build.
- `:193` — the zip must match the manifest's SHA-256 and byte count.
- `:200` — after `ditto -xk`, it takes the first `*.app` in the archive. It never reads the new bundle's identifier, Team ID or code signature.
- `:210-215` — the install target is the running bundle's own path. A translocated or read-only install opens the download page instead.
- `:248-251` — the helper script runs `rm -rf "$TARGET"`, then `ditto "$STAGED" "$TARGET"`, then `open "$TARGET"`.

So 0.1.59 accepts an Otto release signed with the same key and installs `Otto.app`'s contents at `/Applications/Muse.app`. Nothing is rejected; only the folder name is wrong. Otto fixes that itself:

1. On first launch from a `Muse.app` path, Otto renames itself to `Otto.app` after quitting and relaunches (`Sources/OttoApp/AppInstallLocation.swift`). This happens once, for the release bundle only, and only if `Otto.app` is free and the folder is writable.
2. Every Otto update from a `Muse.app` path installs `Otto.app` beside it. `Muse.app` moves to the Trash only after the new bundle is in place (`AppUpdateController.relaunchHelperScript`). An existing `Otto.app` from another vendor is never replaced.
3. Otto's own updater copies the new bundle next to the target and swaps it in with renames. A failed copy leaves the installed app untouched and reopens it.

The feed URL, the `maxtrigify/muse-releases` repository and the key ID must not change; they are `OttoLegacyWire` constants.

### What migrates on first launch

All of this runs before any store opens (`OttoLaunchMigration`) and is logged to `~/Library/Logs/Otto/migration.log`.

- **App folders.** `~/Library/Application Support/Muse`, `Logs/Muse` and `Caches/Muse` are renamed to `…/Otto`, and a `Muse` symlink is left behind so an older build still finds its data. This only happens when `Otto` does not exist yet. If both exist, both are left alone and Otto is used, with one exception: an `Application Support/Otto` without a `workspace.sqlite` next to a `Muse` folder that has one is stray (test runs and debug builds leave `dev-secrets.json` and `Messaging/state.json` there), so it is renamed to `Otto set aside <date>` and the Muse data moves in. A marker file makes an interrupted move resumable.
- **Preferences.** These import once from `app.muse.desktop` (or `app.muse.desktop.dev`), mapping `muse.` to `otto.` and `Muse…` to `Otto…`. Keys Otto already has are never overwritten, and the marker `otto.migration.legacyDefaultsImported` stops a second import.
- **Workspaces.** In every profile's workspace, `.muse` is renamed to `.otto` and a `.muse` symlink is left. `.muse-worktrees` moves the same way when the next agent worktree is created. Checkpoint refs are not rewritten: new ones go under `refs/otto/checkpoints` and old `refs/muse` ones stay readable.
- **Keychain.** Each `io.openotto.*` item is copied from its `app.muse.*` twin the first time it is read. Legacy items are left in place.
- **Unchanged.** User document folders (`~/Documents/Muse Workspace`, `Muse Profiles`) keep their stored paths.

### Permissions people will see once

TCC grants (microphone, screen recording, accessibility, automation, notifications) and keychain ACLs belong to the old bundle identifier and signature. After the first Otto launch, macOS asks again. Each keychain item copied from `app.muse.*` may prompt once; "Always Allow" stops further prompts. People whose data was migrated see a one-time "Otto is the new name for Muse" notice explaining this (`OttoRenameNotice`).

### Release order

1. Merge `codex/otto` into `main` after review, then run the full test suite, the Server package tests, and the iOS simulator build.
2. Choose a version above 0.1.59 (for example 0.2.0) and a build number above the 0.1.59 build. The updater compares both.
3. Add the CHANGELOG entry. Say that Muse is now Otto, that data moves automatically, and that macOS will ask for permissions again.
4. Optional: copy the release key to the new Keychain service once: `security add-generic-password -s otto-release-signing -a <account> -w "$(security find-generic-password -s muse-release-signing -w)"`. `publish-release.sh` falls back to `muse-release-signing` either way.
5. Update the download site copy in the `muse-releases` repository so the manual-download fallback offers Otto. Keep the URL.
6. Rehearse on a spare Mac or VM with 0.1.59 installed and real-looking data. Point it at a staging feed with `MUSE_UPDATE_FEED_URL` (0.1.59 reads only the MUSE_ name), run Download & Restart, and confirm:
   - Otto opens from `Muse.app`, renames itself to `Otto.app` and relaunches.
   - Sessions, settings, provider keys and website logins are present.
   - `~/Library/Application Support/Muse` is a symlink to `Otto`.
   - The notice appears once.
7. Publish with `scripts/publish-release.sh <version> <build>`.
8. Afterwards:
   - **Remote hosts.** Rerun `scripts/install-ottod-linux.sh` or `scripts/bootstrap-ottod-macos.sh`. They migrate `mused` installs, and the Mac keeps reaching an un-migrated `mused` socket until then.
   - **iOS.** The phone app now uses `io.openotto.mobile`. It needs new App IDs, provisioning and an APNs topic (`OTTO_APNS_TOPIC`). People install it as a new app and pair again, because the old app's keychain pairings are not readable by a different bundle.
   - **Commercial server.** Deployments keep working with `MUSE_*` variables, but `compose.yml` now creates an `otto` database user. Set `DATABASE_USER`/`DATABASE_NAME` explicitly when reusing an existing `muse` volume.

## Rollback

Remove the affected release from its channel, add its version to `blockedVersions`, sign and publish the replacement manifest, and restore the preceding notarised artifact. Licensing outages must not revoke cached signed entitlements before their offline grace deadline.

## Credential boundary

Signing keys, notary credentials, update-manifest private keys, licence keys, and provider credentials are never committed. The application embeds only rotating public verification keys. Commercial telemetry must not contain prompts, terminal output, paths, file content, or voice transcripts.
