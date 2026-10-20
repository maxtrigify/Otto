# Otto Mobile notifications

Otto Mobile has two notification paths that share the same canonical `RunEvent` identity and
thread deep link:

- While iOS still grants the app short background execution, the phone schedules a local alert.
- After iOS suspends the app, the Mac host sends the same classified event through APNs.

Completion, failure, approval, and needs-user events are eligible. Terminal notifications come
only from terminal run events; status echoes do not generate a second alert. Each APNs delivery is
persisted per event and paired device before sending. A host crash during an in-flight request
marks the outcome `uncertain` instead of automatically risking a duplicate alert.

## Development provider configuration

Create an APNs token-signing key in the Apple Developer account and keep the downloaded `.p8`
file outside the repository with owner-only permissions. Launch the Mac app with:

```sh
OTTO_APNS_TEAM_ID=YOURTEAMID \
OTTO_APNS_KEY_ID=YOURKEYID \
OTTO_APNS_TOPIC=io.openotto.mobile.dev \
OTTO_APNS_PRIVATE_KEY_FILE=/absolute/private/path/AuthKey_YOURKEYID.p8 \
scripts/otto-swift run Otto
```

If any APNs variable is provided, all four are required. The key material remains on the Mac and
is used only to mint ES256 provider tokens. Otto reuses a provider token for 50 minutes so it does
not violate APNs token-rotation guidance.

Debug builds register sandbox tokens; Release builds register production tokens. Never mix the
development topic/token with the production APNs endpoint.

## Phase 2 physical exit check

1. Install a development-signed iPhone build with Push Notifications enabled in its provisioning
   profile. Pair it with the Mac and turn on alerts in Otto Mobile.
2. Confirm the Mac paired-device record contains a sandbox token and registration timestamp.
3. Start a run, lock the iPhone long enough for the app to suspend, and let the run complete.
4. Confirm one alert arrives, its title names the bot, and tapping it opens the canonical thread.
5. Repeat for needs-user and failure events.
6. Revoke the phone on the Mac and confirm no later event is delivered to it.
7. Force one retryable APNs response in a non-production test environment and verify the durable
   record backs off; force an unregistered-token response and verify it becomes permanently failed.

Record the iPhone/iOS version, app topic, APNs environment, event IDs, and delivery timestamps.
Phase 2 is not fully accepted until the locked/suspended physical-device canary passes.
