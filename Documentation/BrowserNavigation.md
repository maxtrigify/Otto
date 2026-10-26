# Browser navigation boundaries

The Browser place keeps ordinary website windows in its tab strip. Both clicked
`target="_blank"` links and top-level JavaScript `window.open(url)` calls route
through `BrowserLinkTabRequest`; the Zodiac PRO 5.5 configurator uses the latter.
Clicked links always open as tabs, even to login pages such as HeyReach's
`/account/login`. Embedded script popups and script-opened authentication
endpoints retain WebKit's supplied configuration and opener for sign-in callbacks. Blank script windows
also retain their opener. These authentication exceptions still use native windows.

Gmail and Google Calendar account links reuse the current tab only when the
source and destination are the same product and the destination identifies an
account (`/mail/u/...` or `/calendar/u/...`). Google AccountChooser links also
qualify when their decoded `continue` URL matches that product. Google app
launcher links to another product keep normal tab behavior.

Native new-tab URLs (`otto:` and legacy `muse:`) never load in WebKit. The
navigation delegate cancels them, including back/forward swipe requests. Toolbar
history and reported back/forward availability exclude these URLs and
`about:blank`. The native new-tab surface remains available through New Tab.

Pinning is available through the visible pin button beside the address/tabs and
through each tab's context menu. Clicking an existing pin toggles it off. Saved
shortcuts are horizontally scrollable so sites beyond the first six remain
reachable. The existing pinned-site persistence is retained.

Regression coverage lives in `BrowserPopupTests`; `BrowserChromeTests` can export
native chrome previews with `OTTO_BROWSER_CHROME_SNAPSHOTS`. A real WebKit fixture
checks JavaScript popup delivery to the tab owner and cancellation of legacy
internal navigation. Live signed-in Google account switching requires a manual
check in the updated app; tests use URL routing without personal accounts.
