# Otto Design System — Agent Brief

This is the working brief for any agent touching Otto's UI. Otto is a native macOS SwiftUI app with two places over a live themed backdrop: **Home** (the daily brief, pinned cards and a composer) and **Chat** (sessions, bots and teams beside Documents, Dashboards, Automations and an in-app browser). Read this before writing any view code. **The code is the source of truth.**

---

## 1. The theme system (the only formal tokens)

**Colors are the only tokenized design values.** Radii, spacing, and type sizes are literals at call sites (conventions below). There is no `DesignSystem.swift`.

### Definition — `Sources/OttoModels/Themes.swift`

- `ThemeColor` is a linear-RGB triple (`Double` 0–1) with WCAG helpers (`contrastRatio(with:)`, `isLight`).
- `OttoThemeDefinition` has exactly **9 color slots**:

| Token | Role |
|---|---|
| `ink` | Deepest background / window base |
| `surface` | Card backgrounds |
| `raised` | Title bars, input bars, chips |
| `paper` | Primary text (inverts dark on light themes) |
| `muted` | Secondary text, icons, captions |
| `signal` | Primary accent — success, selection, focus |
| `amber` | Working/pending states, permission prompts |
| `red` | Errors, action traces |
| `cyan` | Info, links, browser/agent affordances |

- **13 themes** in `OttoThemeCatalog` (default: `fieldNotes` — near-black ink, warm off-white paper, acid-lime signal). 4 are light (`highfell`, `silverbough`, `mistfall`, `duneveil`). Resolve IDs through `OttoThemeCatalog.theme(id:)` — it handles legacy aliases and falls back to `fieldNotes`.
- The theme is stored on the workspace's active canvas record (the persisted data model still groups nodes into canvases) and set by dispatching `.setTheme(id)` — the `theme.set` tool, so agents can change it too. Not in Settings.
- Two fields are currently **dead**: `traceStyle` (no view reads it) and `nodeOpacity` (plumbed into `OttoPalette` but unconsumed). Don't build on them without wiring them up.

### Hard invariants — `Tests/OttoModelsTests/ThemeTests.swift`

Every theme must pass: `paper`:`ink` contrast ≥ **7.0**, `muted`:`ink` ≥ **4.5**, `signal`:`ink` ≥ **4.5**. Run `swift test --filter ThemeTests` after any theme change.

### Consumption — `Sources/OttoApp/OttoPalette.swift`

`OttoPalette` converts `ThemeColor` → SwiftUI `Color` and is injected via the environment. **The universal idiom:**

```swift
@Environment(\.ottoPalette) private var palette
// ...
.foregroundStyle(palette.muted)
.background(palette.raised.opacity(0.94))
```

Never hardcode colors in views; always go through `palette`. `OttoPalette` is deliberately `Equatable` so SwiftUI can skip invalidation — keep it that way.

## 2. Typography — exactly two fonts

```swift
Font.ottoDisplay(_ size: CGFloat)                    // Avenir Next sans serif — prose, titles, body
Font.ottoMono(_ size: CGFloat, weight: Font.Weight)  // SF Mono — labels, data, metadata
```

Both are `relativeTo: .body` so Dynamic Type applies. The signature recurring pattern is the **micro-label header**:

```swift
Text("REVIEW INBOX — PROPOSED MEMORIES")
    .font(.ottoMono(7.5, weight: .black))
    .tracking(1.2)
    .foregroundStyle(palette.muted)
```

Uppercase literal + tiny mono (5.5–8pt world units) + `.black`/`.bold` weight + tracking 0.8–1.6 + `palette.muted`. Use it for every section header, subtitle, and chip. `ottoDisplay` most commonly appears at 12–14 for body, 15+ for titles.

A global font-scale preference (`otto.appearance.fontScale`, 0.8–1.3) is applied as `.dynamicTypeSize` at the workspace root and multiplied directly into the terminal font.

## 3. The `scale` prop

Node bodies that Chat and Home reuse (`BrowserBody`, `WidgetBody`, `OttoBrowserChrome`) still take a `scale: Double` prop and size themselves as `max(floor, base * scale)`. It is a holdover from the retired zoomable canvas; Chat and Home always pass `1`. New views use plain unscaled literals — no `scale` prop.

## 4. Sizing, strokes, shadows (conventions, not tokens)

**Corner radii** cluster by role: 2–3 accents/quote bars · 5–8 rows/chips/tool calls · 9–10 cards/tables/callouts · 12–13 cards/message bubbles · 16 command palette · 18 large sheets · `Capsule()` for pills.

**Hairline strokes** are near-universal, two families:
- Over theme surfaces: `palette.paper.opacity(0.06…0.16)`
- Over dark chrome: `.white.opacity(0.035…0.12)`

**Shadows**: `.shadow(color: .black.opacity(0.22…0.52), radius: 12…34, y: 5…10)` — deeper/larger when selected.

**Materials — key gotcha**: there are **no** SwiftUI materials in the app (the old TopBar's `.ultraThinMaterial` retired with it). The "glass" look everywhere is layered opacity fills over the live backdrop (`palette.raised.opacity(0.94)`, `palette.ink.opacity(0.48)`, `.white.opacity(0.04)`). The theme's `surfaceMaterial` field does *not* pick a SwiftUI material — it only tunes the backdrop scrim opacity and drives light/dark `preferredColorScheme`. Don't introduce new materials.

## 5. Theme backgrounds

`ThemeBackgroundView.swift` renders the full-bleed backdrop behind everything. Resolution order for a theme's `backgroundAsset` (see `Sources/OttoApp/Resources/Themes/README.md`):

1. Video (`.mov`/`.mp4`) → muted seamless loop (built, no videos shipped yet)
2. Image (`.heic`/`.png`) → still with subtle live motion: Ken Burns "breathe" + per-asset water-shimmer regions tuned in `ImageMotion`
3. Bare name → procedural landscape scene (`LandscapeScenes.swift` — gradient sky, ridges with aerial perspective, mist, clouds)

Dropping a correctly named image into the Themes resource dir upgrades a procedural theme with **no code change**. A 3-stop `ink` gradient scrim preserves text contrast over any art. Animation is capped at **24fps** via `TimelineView`. The accessibility ladder is non-negotiable: reduced transparency → solid ink, no backdrop; reduced motion → static frame. Never bypass `ThemeBackgroundView`.

## 6. Home and Chat

`WorkspaceView.swift` hosts the Home / Chat switch, the command palette and the app-wide sheets. `PersonalHomeView.swift` is Home; `ChatWorkspaceView.swift` is Chat and its places (sessions, bots, teams, Documents, Dashboards, Automations, Browser).

The spatial canvas (a zoomable board of draggable node cards) was retired in October 2026. Its data model stays: sessions, bots, browsers, documents and widgets are still persisted as nodes on canvases, and Chat lists sessions from every canvas. Don't reintroduce canvas-only presentation (viewport, node frames, layouts) into the UI.

## 7. Terminals

`EmulatedTerminalView.swift` wraps **SwiftTerm** (`NSViewRepresentable`); ANSI parsing is fully delegated — no custom escape-code handling. 10k scrollback, mouse reporting, option-as-meta. Output feeds incrementally via `TerminalRenderPlanner` (OttoRuntime), which sends only new bytes and a full-reset escape on session change. PTY lifecycle lives in `OttoRuntime` (`PTYProcess`, `AgentSupervisor`).

**Known inconsistency — the biggest one in the app**: the terminal ignores the theme. It hardcodes `NSColor(white: 0.045)` background / `white: 0.92` foreground and uses `monospacedSystemFont(ofSize: 11)` instead of SF Mono via `ottoMono`. Its font scales off the user font-scale preference. The planned `terminalPalette` theme field was never implemented. If asked to theme the terminal, this is the gap.

## 8. The web browser

A full browser rendered in Chat's Browser place and beside work (`ChatBrowserPlace.swift`, `OttoBrowserChrome.swift`, `BrowserBody.swift`). WebKit sessions are owned by `BrowserRendererPool`, not by whichever panel is visible.

- **Toolbar**: `palette.raised.opacity(0.94)`, bottom hairline; address field is mono text on `palette.ink.opacity(0.48)` at radius `7 * scale`, lock icon in `cyan` for https. Circular `ChromeButton`s tint `cyan` when active.
- **Vertical tab sidebar** (not horizontal tabs): `palette.ink.opacity(0.74)`, "PERSONAL" micro-label header, rows with favicons (`AsyncImage` off `/favicon.ico`, letter-tile fallback), active row = `palette.paper.opacity(0.075)` fill, close button on hover.
- **Bookmarks bar** on `palette.surface.opacity(0.92)` with Gmail/Linear/GitHub/Google defaults.
- **Start surface**: `ink` + a faint cyan radial glow, centered search card on `raised.opacity(0.66)`.
- **Agent rail**: a side panel ("OTTO AGENT / BUILD MODE") listing agent activity rows — each kind maps to an SF Symbol and color (evidence→`signal`, success→`cyan`, failure→`red`). Persistent footer: "You can take over at any time."
- **Agent-control aura** (`BrowserAgentControlAura`): when an agent drives the browser, a rotating `AngularGradient` border sweeps the web view every 3.6s — `signal` when acting, `cyan` when observing; frozen under reduce-motion. This is the canonical "agent is in control" affordance; reuse it rather than inventing new ones.

`BrowserImportView.swift` (bookmark import sheet): unscaled literals, radius 10 rows, `cyan` checkmarks.

## 9. Other surfaces, quickly

- **Command palette** (`CommandPaletteOverlay.swift`): black 0.62 scrim, fixed 760×540 panel on `surface` at radius 16. Selected row **inverts** — `signal` background with `ink` text. Search field is `ottoDisplay(19)`.
- **Markdown renderer** (`MarkdownMessageView.swift`): from-scratch; heading multipliers 1.45/1.25/1.12/1.0 of a `baseSize`; `signal` bullets and blockquote bars; code blocks on `ink.opacity(0.6)` at radius `9 * scale`; mono `.black` table headers.
- **Agent conversations** (`AgentConversationBody.swift`): user messages are right-aligned `raised` bubbles at radius `13 * scale`; assistant messages full-width with a mono provider header; tool calls on `raised.opacity(0.55)`; permission prompts framed in `amber` (0.09 fill / 0.22 stroke). MCP tool names render as `server · tool name`.
- **Whiteboard**: whiteboard nodes and the `whiteboard.*` tools persist an Excalidraw scene plus queued `WhiteboardAction`s. The in-app Excalidraw renderer lived on the retired canvas, so no Home or Chat view draws whiteboards today; the vendored build in `Resources/Excalidraw` is kept for a future surface.
- **Settings** (`ProductSettingsViews.swift`): the deliberate exception — native SwiftUI `Form`/`Toggle`/`Color.accentColor`, no palette, no Otto fonts. Keep settings native; don't "fix" this without a decision.

## 10. Rules of engagement for agents

1. **Colors**: only via `@Environment(\.ottoPalette)`. Map semantics, don't pick hues: success/selection→`signal`, busy→`amber`, error→`red`, info/agent/links→`cyan`, chrome text→`paper`/`muted`.
2. **Fonts**: only `ottoDisplay` (sans-serif prose) and `ottoMono` (labels/data). Section headers use the uppercase-tracked-mono micro-label idiom.
3. **Plain literals for sizes.** Only the legacy node bodies in §3 take a `scale` prop.
4. **No new materials, no new blur.** Glass = opacity layering over the themed backdrop.
5. **Respect reduce-motion and reduced-transparency everywhere**; animations should have a `nil`/static branch.
6. **Keep the data model, not the board.** Nodes and canvases are storage; present them through Home and Chat (§6).
7. **New/changed themes must pass `ThemeTests`** contrast floors.
8. Radii/spacing have no tokens — match the numeric clusters in §4 rather than inventing new values.
9. Ignore files suffixed `" 2"`/`" 3"` — untracked duplicate copies; canonical filenames only.
