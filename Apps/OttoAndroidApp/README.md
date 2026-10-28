# Otto Android companion

This project builds an installable Android APK for the existing Otto Mac mobile
host. It uses the Android SDK and Kotlin, with no Compose/AndroidX dependency.
The Android application ID is **`io.openotto.android`**. Android 13 (API 33)
or newer is required; the app targets API 35 and builds against SDK 35.

Version **0.1.1** fixes Android 15–17 safe-area/keyboard spacing on taller
phones, including the Galaxy S25 Ultra. Home and Bots stay scrollable without
being covered by the bottom gesture bar. Background synchronization is quiet:
it refreshes conversations about every 8 seconds and Home about every 20
seconds without redrawing an unchanged screen or jumping away from older chat
messages. Tap **Refresh** or **Sync** for an immediate update.

The Android launcher uses the repository's original Otto icon artwork from
`packaging/AppIcon-1024.png`, scaled to Android's five standard launcher
densities, rather than the earlier Android-only monogram placeholder.

The Mac remains the host for its conversations, bots, teams, activity and
agent execution. The phone connects to the paired Mac over an HTTPS endpoint;
it is not a substitute for running Otto on the Mac. The source of truth for
the mobile host and pairing protocol remains the existing Mac/iPhone code.

## Build a debug APK on Mac

Prerequisites: JDK **21**, Android SDK platform **35** with build-tools
**35.0.0**, and an internet connection on the first build if dependencies are
not already cached. The checked-in Gradle wrapper uses **Gradle 8.14.3**, and
the application uses **Android Gradle Plugin 8.13.0**, Kotlin **2.0.21**.

```sh
cd Apps/OttoAndroidApp
ANDROID_HOME="$HOME/Library/Android/sdk" \
  ./gradlew --no-daemon :app:assembleDebug
```

The installable APK is created at
`Apps/OttoAndroidApp/app/build/outputs/apk/debug/app-debug.apk` from the
repository root. The Android SDK debug signing key signs this APK for local
testing; it is not a production release signing identity.

For a USB-connected Android phone with USB debugging enabled:

```sh
"$HOME/Library/Android/sdk/platform-tools/adb" devices
"$HOME/Library/Android/sdk/platform-tools/adb" install -r app/build/outputs/apk/debug/app-debug.apk
```

Alternatively, copy the APK to the phone and open it with the Android package
installer. Android may ask you to allow installation from the chosen file
manager/browser. The debug APK should not be distributed as a trusted Play
Store release; a production release would need its own protected signing key,
release configuration and store review.

## Pair with Otto on Mac

1. Launch the existing Otto Mac app. Open **Settings → Mobile** to find the
   one-time pairing QR or `otto://pair?...` code. Keep the Mac running.
2. Make the Mac mobile host reachable at a trusted **HTTPS** URL. For remote
   access, sign in to the same Tailscale tailnet on both devices and set up
   **Tailscale Serve**, which can proxy the Mac's private mobile host to a
   tailnet HTTPS address. Do not use Tailscale Funnel (public internet).
   The Mac host defaults to `127.0.0.1:7338` (or 7340 for Otto Dev); a custom
   `OTTO_MOBILE_HOST_PORT` may be used if another app owns that port.
3. Open Otto on Android and paste the current Mac `otto://pair?...` link into
   **One-time pairing link**. Enter the Mac's private HTTPS Tailscale address
   into **Secure Mac address**, such as
   `https://your-mac.your-tailnet.ts.net:7339/`. Tap **Connect Mac** and review
   the Mac identity. A pairing QR that advertises Mac-local `127.0.0.1` still
   works: the Android client uses your HTTPS address for transport while
   validating the original identity and fingerprint from the Mac QR.
4. Confirm the home and chat screens load. A Mac relaunch or a new
   `OTTO_MOBILE_HOST_PUBLIC_URL` is **not required** for the HTTPS override;
   that environment variable is optional for future direct HTTPS pairing QR
   generation.

The Mac repository contains `scripts/otto-mobile-tailscale preflight` to show
the relevant Tailscale DNS name and endpoint before configuring remote access.
For custom ports, read `scripts/otto-mobile-tailscale` and inspect existing
`tailscale serve status` routes before making changes. That helper defaults
to proxy port 7338 and HTTPS port 443; configure separate ports only after
checking for conflicts. For example, a Mac mobile host configured on 7339
must be routed to 7339, not to the Linux browser service on 9797.

Android deliberately disables cleartext traffic in the manifest, and pairing
credentials must remain on the device in the Android Keystore backed store.
Only pair with a Mac and HTTPS certificate you trust. Do not put tokens or
pairing codes into CI variables, bug reports, or screenshots.

## CI downloadable APK

The `.github/workflows/android-apk.yml` GitHub Actions workflow builds a
real **debug APK** on Ubuntu with JDK 21 and Android SDK 35. It runs for
Android project changes and can also be started under **Actions → Android
companion APK → Run workflow** on the repository hosting the branch.

After a successful run, open the workflow run and download the artifact named
`otto-android-debug-apk`. The ZIP contains `app-debug.apk` and its SHA-256
checksum file. The artifact is retained for 30 days. The workflow validates
the Gradle wrapper, builds the
actual Android project, verifies the APK is nonempty, and fails if any step
or upload is unsuccessful.

## Troubleshooting

If Gradle cannot locate the SDK, set `ANDROID_HOME` to your SDK directory or
create a developer-local `local.properties` file containing an `sdk.dir`
entry; that file is ignored by Git. Run `java -version` to verify JDK 21.
If Android reports the Mac is unreachable, confirm both Tailscale devices
are connected, visit the advertised HTTPS `/health` URL from the phone,
and ensure the pairing offer is still valid. Generate a new pairing code if
it expired; avoid modifying the stored Mac identity to bypass validation.
