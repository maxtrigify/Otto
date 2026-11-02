# OttoCSQLite

SQLite for Linux and Windows builds. The Mac uses Apple's system SQLite instead.

The amalgamation (SQLite 3.53.4, public domain) is the copy shipped by
swiftlang/swift-toolchain-sqlite 1.0.13 (`sqlite3.c` sha256
`b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189`). It is compiled here with
FTS5 and the other features Apple's SQLite has, because that package builds it with none, and
Otto's project brain search needs FTS5. Without it, memory storage fails on Linux and Windows.
That failure stopped tool registration and left bots without their browser and other tools.

To update it, replace `sqlite3.c`, `include/sqlite3.h` and `include/sqlite3ext.h` with a newer
amalgamation from https://sqlite.org/download.html.
