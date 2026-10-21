# Google sign-in popup investigation

Status on 2026-10-21: **unresolved**. No Google/X login fix is included in the
popup ownership extraction or its regression test.

## Observed in the installed Otto app

- Open X, choose Sign in with Google, and select an existing Google account.
- The native account chooser closes, but X remains on its signed-out landing page.
- Both a direct mouse click and an accessibility click reproduce the result.
- Dismissing X's cookie banner does not change the result.
- No password was entered or recorded during this investigation.

## Controlled coverage

`BrowserPopupTests.iframePopupReturnsMessageBeforeClosing` uses a disposable
local server and nonpersistent WebKit storage. A cross-origin iframe opens a
popup, the popup posts a message to its opener and immediately closes, and the
iframe relays the result to the parent page. This passes with the existing
popup behavior. It does not reproduce Google's credential callback or prove
that Google sign-in works.

`BrowserPopupWindows` keeps the WebKit-supplied child configuration, including
its opener relationship, and retains each native popup until it closes. The
extraction makes that existing behavior testable; it is not a login workaround.

## Remaining verification

Reproduce Google/X with the updated build and trace the provider handoff without
recording credentials, cookies, or OAuth payloads. The installed app was not
replaced or restarted during this investigation because it hosts active work.
Do not describe this issue as fixed until the real X flow signs in successfully.
