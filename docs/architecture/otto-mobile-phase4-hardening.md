# Otto mobile Phase 4 hardening evidence

Date: 2026-08-29
Status: local release and simulator gates passed; physical-device and signed-distribution gates pending

## Release construction

- The macOS packaging and release-publishing scripts invoke SwiftPM only through
  `scripts/otto-swift`, preserving the repository's worktree-isolated cache, lock, and timeout
  guarantees.
- The Swift wrapper's timeout watchdog is a single process. Cancelling it no longer leaves an
  orphaned `sleep` holding command-substitution pipes open until the full timeout.
- A clean-cache build exposed a missing `OttoRemote` dependency in
  `OttoCommercialServerTests`; the manifest now declares it explicitly.
- The optimized build passed with warnings treated as errors after redundant HTTP response casts
  were removed from the mobile connection and pairing clients.
- Ad-hoc archive: `.build/phase4-distribution/Otto-0.1.0.zip`
- SHA-256: `550c630a449343c104452b03705c4aa9bd374d856a752aa55abeff5839687480`
- `scripts/verify-release.sh` passed ZIP integrity, metadata, deep strict code-signature, required
  resources, and packaged helper smoke checks.

This host has no Developer ID identity or configured notarization profile. The archive evidence is
therefore an ad-hoc distribution check, not notarization evidence.

## Automated regression evidence

- `OttoSecurityTests`: 4 tests in 2 suites passed.
- `OttoRemoteTests`: 35 tests in 12 suites passed.
- `OttoMobileClientTests`: 18 tests in 3 suites passed.
- `OttoCommercialServerTests`: 16 tests in 6 suites passed.
- `OttoAppTests`: 34 tests in 12 suites passed.
- Live local pairing UI E2E passed on an iPhone simulator using a fresh app install and a real
  loopback host: review connection, pair this iPhone, and open the paired home.
- Cold-offline UI E2E passed: a live canonical thread was cached, the host became unavailable,
  the home relaunched as offline, and the cached transcript remained readable.
- Background-completion UI E2E passed: the native permission sheet was accepted, a run completed
  while the app was backgrounded, the completion notification appeared, and tapping it deep-linked
  back to the canonical Ada thread.
- Stream/relaunch UI E2E passed: a unique message streamed from the live loopback host, its active
  run was interrupted, and relaunch restored exactly one copy from snapshot and cursor replay.
- Local and managed pairing-review UI E2Es passed. Both routes required an explicit review before
  exchange and exposed the Mac identity or relay trust boundary respectively. The local fixture now
  explicitly clears Keychain pairing state because uninstalling an iOS app does not reliably clear
  its test credential.
- Bot/team UI E2E passed: the paired home rendered the saved team and inactive Nova bot, and tapping
  Start opened Nova's canonical thread on the Mac.
- The complete nine-case mobile UI simulator matrix passed after the visual redesign: local and
  managed trust review, live local exchange, bot start, stream/interrupt/relaunch deduplication,
  cold offline recovery, background notification deep linking, active managed relay, and expired
  subscription handling.
- Background-completion delivery now holds a short iOS background task only while a run is active
  and schedules its local banner one second after the event. This closes the transition race where
  a completion could be suppressed while the app was moving from foreground to Home. The simulator
  harness also uninstalls the app for this case so the native first-run authorization sheet is
  deterministic.

## Human platform-use pass

- The exact archived macOS application was extracted and launched with onboarding forced on.
  The onboarding sheet remained within the available display, used a compact two-column provider
  grid, kept the acknowledgment and action footer visible, and clearly separated local private
  voice from optional cloud Talk.
- The paired iPhone simulator home was visually inspected after the live pairing flow. It showed
  an honest live state, Mac health, alerts, bot and team roster, and the expected editorial mobile
  hierarchy without clipping or overlap.
- The offline canonical thread was visually inspected at an iPhone-sized viewport. It preserved
  the transcript and composer while clearly labelling the host `OFFLINE`.
- The mobile visual system now follows the desktop's transparent themes: Glasswing in light mode
  and Nightglass in dark mode. Pairing, home, bot/team roster, threads, composer, attachments, and
  diagnostics use adaptive glass surfaces over a lavender/cyan atmospheric backdrop. iOS 26 uses
  native interactive glass effects; older systems use material fallbacks, and Reduce Transparency
  receives solid readable surfaces.
- Light and dark simulator captures were inspected for pairing identity review, paired home, bot
  start, and canonical thread views. Text contrast, glass boundaries, controls, and safe-area
  spacing remained readable without clipping in both appearances.

The macOS automation bridge closed its native pipe on click attempts, and Accessibility denied the
AppleScript fallback. The packaged desktop pass therefore provides launch, accessibility-tree, and
visual evidence, but does not claim automated click-through evidence for that exact archive.

## Physical exit criteria still pending

The following gates cannot run on the current host and must not be inferred from simulator or
loopback results:

- Tailscale preflight and a two-network Wi-Fi/cellular reconnect canary: the Tailscale CLI is not
  installed and no physical iPhone is connected.
- Locked/suspended-device APNs delivery: APNs credentials are not configured and no physical
  iPhone is connected.
- Developer ID signing and notarization: this keychain contains no valid signing identity and no
  notary profile is configured.

Phase 4 can be called locally hardened, but final launch certification remains open until these
three physical/signed-distribution gates produce dated evidence.
