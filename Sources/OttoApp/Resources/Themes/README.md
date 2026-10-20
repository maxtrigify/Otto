# Theme background assets

Drop theme backdrop media in this directory; it ships inside the app's SwiftPM
resource bundle (`Otto_OttoApp.bundle/Themes/`).

A theme references media through `backgroundAsset` in `OttoThemeDefinition`
(`Sources/OttoModels/Themes.swift`):

- `"name.mov"` / `"name.mp4"` / `"name.m4v"` — muted, seamless loop played full-bleed.
- `"name.heic"` / `"name.png"` / `"name.jpg"` — full-bleed still with subtle live
  motion (slow Ken Burns breathe + specular water shimmer; tuned per asset in
  `ImageMotion` in `ThemeBackgroundView.swift`).
- `"name"` (no extension) — resolves in priority order: a dropped-in `name.<video>`
  file, then `name.<image>`, then the built-in procedural scene of that name
  (`aurora`, `highfell`, `silverbough`, `mistfall`, `duneveil`).

So to give a landscape theme real painted artwork, just add e.g. `highfell.png`
here — the theme upgrades from its procedural scene automatically. Target ~2560px
wide, landscape-only compositions (no people or creatures), original or licensed
art only.

Production pipeline for filmed/generated backdrops:

1. Generate or shoot a hero image for the theme.
2. Animate it (e.g. Kling) into a 10–20 s seamless loop, 1080p+ H.264/HEVC, no audio.
3. Drop the file here and set `backgroundAsset` on the theme definition.
4. Derive the theme palette from the animated footage and validate contrast —
   `swift test --filter ThemeTests` enforces the theme contrast invariants.

Licensing: original or licensed artwork only. No
third-party app's assets or look-alike recreations.

Accessibility (handled by `ThemeBackgroundView`, do not bypass it):

- Reduced transparency → backdrop is not rendered at all (solid ink).
- Reduced motion → first frame shown as a static poster.
- A surface-material scrim preserves text contrast over live footage.

Exception on record: `nightscreen.heic` is a painted character illustration (an original,
generated for Otto — not derived from any third-party work). It was added deliberately for
the Nightscreen theme, whose whole idea is artwork behind smoked glass; the landscape-only
guidance above still applies to every other bundled backdrop.
