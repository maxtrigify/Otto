# ADR 0008: Owned Chromium renderer and semantic browser control

## Status

Accepted; the renderer-neutral control plane and WebKit bridge are implemented. CEF embedding is
the next packaging milestone.

## Decision

Muse will own the browser experience and profile while embedding Chromium through CEF. Browser
nodes will not attach to, copy live cookies from, or remotely control a user's Chrome, Dia, Safari,
or Firefox profile.

Agents interact with pages through a renderer-neutral semantic API:

1. `browser.inspect` returns visible interactive elements with accessibility-shaped roles, names,
   bounds, supported actions, an opaque element ID, and a page revision.
2. `browser.click`, `browser.type`, and `browser.scroll` operate on that revision. A stale revision
   is rejected instead of clicking whatever later appeared at the same coordinates.
3. Password fields are marked sensitive and their values are never returned by inspection.
4. Click and type are consequential, confirmation-gated tools. Inspection is read-only.

The current WKWebView implementation provides the same contract during migration. The CEF adapter
will implement it with the Chrome DevTools Protocol `Accessibility`/`DOMSnapshot` domains for
inspection and the `Input` domain for interaction. This keeps tool contracts stable across the
renderer swap and permits coordinate input only as a fallback.

## Chromium packaging boundary

`Config/cef.json` pins matching Apple Silicon and Intel CEF minimal distributions. The installer
verifies the checksum published by the official CEF automated-build index and extracts only under
`.build/cef`.

The shipping integration must additionally:

- compile the CEF C++ wrapper and a narrow Objective-C++ bridge;
- bundle `Chromium Embedded Framework.framework`, Resources, and the required helper applications;
- create one persistent Muse profile directory per workspace/account policy;
- copy imported bookmarks and shortcuts, but never silently copy browser cookies or passwords;
- sign nested helpers and the framework before signing and notarizing `Muse.app`;
- expose Chromium version/update status in browser settings;
- disable arbitrary remote debugging in release builds and authenticate the internal control path.

## Consequences

Muse gets current Chromium site compatibility, deterministic browser updates, persistent Muse-owned
sessions, and a first-class agent control surface. The cost is a substantially larger app bundle,
ongoing Chromium security updates, CEF helper-process packaging, and additional notarization work.
