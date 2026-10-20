# ADR 0004: Spawn PTY children without a multithreaded fork window

## Status

Accepted.

## Decision

Muse allocates a pseudo-terminal with `posix_openpt`, configures the slave and window size, and launches the child with `posix_spawn`. On Darwin, spawn attributes create a new session, reset the signal mask/defaults, and enable close-on-exec-by-default. On Linux, the spawned `/usr/bin/setsid --wait --ctty` wrapper creates the session and controlling terminal without an application-side fork, and `/usr/bin/env --chdir` changes to the registered workspace. File actions open the PTY slave as standard input/output/error on both platforms.

The previous `forkpty` path could leave a child stranded before `exec` when unrelated `Foundation.Process` work happened concurrently in the multithreaded application/test process. A parent-side lock could serialize Muse PTYs but could not cover process creation in other modules or dependencies.

## Consequences

- There is no application-code execution in a post-fork child.
- Interactive input, process-group signals, terminal sizing, fast-exit draining, high-volume output, and 30 concurrent runtimes remain acceptance tests.
- On Darwin, an immediate nonblocking exit probe remains alongside the kernel process source so a child that exits before source delivery is still reaped exactly once. Linux uses a dedicated blocking `waitpid` queue because Dispatch process sources are unavailable there.
- Linux requires the standard util-linux `setsid` and coreutils `env` executables. The Ubuntu CI/package gate verifies these assumptions; it must pass before the Linux artifact is promoted.
