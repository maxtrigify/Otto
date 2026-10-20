# Dev → Prod workflow

Two installed apps, two branches:

| | Otto Dev.app | Otto.app (prod) |
|---|---|---|
| Source | Your working tree (whatever is checked out, including uncommitted changes) | `main` only, via an isolated git worktree |
| Branch | `dev` (day-to-day work) | `main` (approved changes only) |
| Build config | debug | release |
| Bundle ID | `io.openotto.desktop.dev` | `io.openotto.desktop` |
| Install location | `~/Applications/Otto Dev.app` | `/Applications/Otto.app` |
| Script | `scripts/dev-app.sh` | `scripts/prod-app.sh` |

## Day-to-day loop

1. Work in the canonical development checkout. Try changes in the dev app:

   ```sh
   scripts/dev-app.sh reload   # rebuild + relaunch Otto Dev.app
   ```

   There is exactly one live development source. Invoking this command from a linked worktree or
   an isolated Otto clone routes back to the primary checkout, so parallel agents cannot take turns
   replacing `Otto Dev.app` with mutually exclusive builds. Use `scripts/dev-app.sh status` to see
   the canonical source and the source stamped into the installed bundle.

   Agents whose edits need to hot reload together should share the canonical checkout (with
   **Isolated Git worktree** disabled) and avoid overlapping files. Agents using isolated worktrees
   must commit and integrate their work first; uncommitted states from separate worktrees cannot be
   safely composed into one executable.

2. When a change is ready, commit on `dev` and merge it into `main` once approved —
   either by PR (`dev` → `main` on GitHub) or locally:

   ```sh
   git switch main && git merge dev && git switch dev
   ```

3. Update the prod app from the newly approved `main`:

   ```sh
   scripts/prod-app.sh install
   ```

   The script fast-forwards local `main` from `origin/main` when it can (so PR merges
   are picked up automatically), checks `main` out into a throwaway worktree under
   `~/Library/Caches/Otto/prod-checkout`, builds release, and atomically swaps
   `/Applications/Otto.app` (the previous app is restored if anything fails).

`scripts/prod-app.sh status` shows the installed version, build number, and the exact
commit it was built from, next to the current tip of `main` — so you can see at a glance
whether prod is behind.

## Notes

- The prod build never reads your working tree, so uncommitted or unapproved work
  cannot end up in `/Applications/Otto.app`.
- Both apps currently share the same workspace data (`~/Documents/Otto Workspace`, or the
  existing `~/Documents/Muse Workspace` from before the rename, and
  `~/Library/Application Support/Otto`). Keep that in mind when testing destructive
  changes in the dev app. On first launch either app moves the pre-rename
  `~/Library/Application Support/Muse` (and `Logs/Muse`, `Caches/Muse`) to the `Otto` name and
  leaves a `Muse` symlink so an older build still finds the same data.
- Overrides: `OTTO_PROD_REF` (default `main`), `OTTO_PROD_APP_PATH`,
  `OTTO_PROD_CODESIGN_IDENTITY`, `OTTO_VERSION`, `OTTO_PROD_BUILD_JOBS`. The pre-rename
  `MUSE_*` names are still read when the `OTTO_*` one is unset.
- For distributable, notarized builds use `scripts/package-macos.sh` /
  `scripts/notarize-macos.sh` as before.
