# Agent worktrees and SwiftPM

Otto uses explicit isolation for concurrent coding tasks. A Codex chat does not
automatically own a Git worktree, so each active coding task must be given one.

## Start a coding task

From the integration checkout:

```sh
scripts/otto-worktree create voice-fix origin/main
cd ../Otto-worktrees/voice-fix
```

Worktrees created before the rename stay in `../Muse-worktrees/`; `otto-worktree remove`
still finds them there. Existing worktrees are never moved.

This creates `codex/voice-fix`. Run Swift commands only through the wrapper:

```sh
scripts/otto-swift test
scripts/otto-swift test --filter VoiceSessionTests
scripts/otto-swift build -c release
```

The wrapper derives a stable task ID from the worktree path, stores build and
package state under `~/Library/Caches/Otto/SwiftPM/<task-id>` (an existing pre-rename
`~/Library/Caches/Muse/SwiftPM` is reused until the app migrates it), prevents two
commands from sharing that task directory, and terminates the complete SwiftPM
process group on cancellation or timeout.

Normal commands use exactly the versions in `Package.resolved` and do not update
dependencies. Update dependencies only from an intentional integration task:

```sh
scripts/otto-swift resolve
```

## Diagnose a stuck build

```sh
scripts/otto-swift-doctor
```

If it reports confirmed Otto processes with parent PID 1, terminate only those:

```sh
scripts/otto-swift-doctor --kill-orphans
```

Do not run `pkill swift`, `killall git`, or similar broad cleanup commands.

## Finish a coding task

Commit the task and report its branch, commit SHA, and worktree path. After the
commit is integrated, remove the clean checkout from the integration checkout:

```sh
scripts/otto-worktree remove voice-fix
```

The removal command refuses dirty worktrees and creates an archive branch at the
final commit before asking Git to remove the checkout.

## Integration and release scripts

Existing packaging scripts intentionally use repository-local artifact paths.
Run them from the integration checkout only, with no other Otto Swift build
active. They are not safe parallel task runners.
