# Nightglass mobile and pairing

The iPhone app now defaults to Nightglass regardless of the device's system appearance. Its dark material surfaces use the desktop theme's charcoal base and lavender accent, with subdued background light, Dynamic Type headings and system body text. Reduce Transparency keeps opaque, readable surfaces.

## Connect an existing Otto workspace

1. Install the signed iPhone build when distributed through TestFlight or the App Store.
2. On the Mac, open Otto → Settings → Mobile.
3. Show a Pair nearby code for the same network, or a Remote Access code for a configured managed account.
4. In the iPhone app, scan the QR code and review the connection before confirming.

The iPhone stores its device pairing in Keychain and restores it on later launches. This links to the existing Mac/workspace; it does not create another agent account. Agents execute on the Mac, which needs to remain available. Managed Remote Access also requires its configured service and subscription. Paste-code entry remains available under “Have a pairing code?”.

The source project is not itself a public download. Its development team is not configured in the project; signed physical-device validation, TestFlight distribution and App Store release remain release work. Simulator tests exercise code review and credential exchange, not physical camera scanning or real APNs delivery.

## Deleted bot names

Deleting a bot archives its stable identity and related history. Name uniqueness now applies only to active profiles, so a new identity can reuse an archived name. Case, whitespace and diacritic normalization still prevent active duplicates. Restoring a conflicting identity fails before its channels, notes, connections or routines are restored. The archived identity can be restored after the replacement is renamed or archived.

## Validation (2026-09-07)

- 38 tests across AgentProfileStoreTests and BotModeStoreTests passed.
- iOS simulator UI checks passed: scan-first onboarding and manual disclosure, live pairing exchange and home, message send/interrupt and recovery after relaunch.
- Welcome, home and thread screenshots were reviewed. Final onboarding was rerun after the accent correction.
- Swift formatting and whitespace checks passed. No physical camera or distribution release is claimed.
