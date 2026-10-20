# Contributing to Otto

Thanks for helping. Otto is a native macOS app written in Swift, so most changes are
Swift with SwiftUI, plus a little bundled JavaScript for the whiteboard and diagrams.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on the approach.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Build and test

You need macOS 15 or newer and Xcode 26 or newer (Swift 6.2). No Apple Developer account
or signing identity is required.

```sh
swift build
swift run Otto                       # launch a development build
swift test --no-parallel             # the suite runs serially
xcrun swift-format lint --strict --recursive Sources Tests Package.swift
```

Tests that launch provider CLIs (Claude Code, Codex, Cursor and others) only run when those
tools are installed. The suite never makes paid API calls.

`scripts/dev-app.sh reload` installs a self-reloading **Otto Dev** app in
`~/Applications`. It creates a local self-signed identity on first run.

## Pull requests

- Keep each pull request focused on one change, and describe what it does and how you tested it.
- Add or update tests for behaviour changes.
- Run swift-format and make sure `swift build -c release -Xswiftc -warnings-as-errors` passes.
- Don't commit credentials, personal paths or generated build output.

## Sign your commits (DCO)

Every commit must be signed off to show you have the right to contribute it, under the
[Developer Certificate of Origin](DCO). Add the sign-off with `-s`:

```sh
git commit -s -m "Fix the thing"
```

That adds a line like `Signed-off-by: Your Name <you@example.com>` to the commit message. To
sign off commits you've already made, run `git rebase --signoff main` and force-push your
branch. A check on each pull request confirms every commit is signed off.

There's no separate agreement to sign. By contributing, you agree that your contributions are
licensed under the [Apache License 2.0](LICENSE), the same license as the rest of Otto.

## Name and logo

The Apache license covers the code, not the Otto name or logo. If you publish a fork, give it
its own name and icon. See [TRADEMARKS.md](TRADEMARKS.md).

## Working with coding agents

If you use coding agents on this repository, [AGENTS.md](AGENTS.md) has the worktree and
SwiftPM conventions they should follow.
