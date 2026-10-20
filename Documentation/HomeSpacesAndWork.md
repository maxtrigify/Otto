# Home, spaces, automations and work pages

How Otto's personal-OS surfaces fit together: Home and its brief, spaces, automations, and the
Dashboards and Documents pages (documents, spreadsheets and presentations) built for working
with agents.

## Words that are easy to mix up

| Word in the app | What it is | Code type |
|---|---|---|
| Space | A separate place (Work, Personal) with its own folder, chats, bots and brain | `OttoProfile` |
| Home profile | The Home view inside a space, which owns the brief | `HomeProfile` |
| Bot | A saved assistant with a name, instructions and model | `AgentProfile` |
| AI account | A Claude Code, Codex or other provider login or API key. Accounts are Mac-wide, so every space can use all of them, and a space can use several | `ProviderAccount` |

A space is not an account: one space can read from several AI accounts, and one account can
be used in every space.

## Spaces

A space (Work, Personal, Side Hustle…) is a separate place: its own folder, database, About me,
bots, chats and brain. `OttoProfileRegistry` keeps the list in
`Application Support/Otto/profiles.json`; code types are still called `OttoProfile`. The original
workspace becomes "Work" and keeps its existing database. Switching spaces relaunches Otto into
the chosen one. Agents can only look into other spaces when the user turns on cross-space access
for this space (`profile.list`, `profile.search`, read-only). The spatial Canvas has been
retired; canvases remain only as the storage that groups nodes, and Chat lists sessions from all
of them.

## Home

- **Brief** (`DailyBrief`, `DailyBriefStore`, `.otto/home-brief.json`): Your day, Top to-dos and
  New updates, shown only when there is something worth saying. Users add to-dos; agents use
  `brief.add`/`brief.list`; an automation can deliver into it (`RoutineDelivery.brief`). Each
  space has an Otto-managed morning brief automation. When more than one AI account is signed in
  to the brief's provider, Otto adds one read-only run per extra account
  (`syncMorningBriefAccounts`, `HomeProfile.briefAccountRoutines`). These runs copy the main
  run's schedule, who runs it and whether it is on. Items are labelled with their account, and
  a meeting or to-do that arrives from two accounts shows once. Deleting an account's run leaves
  that account out (`briefSkippedAccountIDs`). Accounts that only use the Mac's own login, and
  briefs run by an already-open agent, get no extra runs.
- **Cards** (`HomeCard`, `HomeCardsStore`, `.otto/home-cards.json`): list, metrics (numbers with
  change and sparkline), line, bar and text. Agents use `home.list_cards`, `home.add_card`
  (refuses a look-alike until the user picks New card or Add to existing), `home.update_card`,
  `home.remove_card` and `home.keep_card_fresh`, which links a read-only automation through
  `RoutineDelivery.homeCard`. Every card can say how it was made (`source`).

## Automations

`AutomationsView` lists routines in plain words with a four-question editor: what, who (a bot or
a fresh Claude Code/Codex agent), which AI account (`Routine.accountID`), when
(`AutomationSchedule` ↔ cron), and where results go (brief, a Home card, the bot's chat).
`RoutineManagerView` remains as Advanced settings. Persisted names stay "Routines".

## Dashboards

Named pages of Home cards (`Dashboard` in `HomeCardsStore`; cards carry `dashboardID`). Agents
use `dashboard.create`/`dashboard.list` and the `home.*` tools with `dashboard`. Describing a
dashboard creates it and binds a helper agent to it.

## Documents

Files live in the space's `Documents/` folder and are managed by `OfficeStore`:

| Kind | File | Editor | Agent tools | Exports |
|---|---|---|---|---|
| Document | `.docx` (NSAttributedString) | `DocEditorView` (NSTextView) | `docs.read`, `docs.suggest_edit`, `docs.write` — changes arrive as Accept/Reject suggestions | Word with real headings and lists (`DocxWriter`), PDF |
| Spreadsheet | `.ottosheet` (`Spreadsheet` JSON; legacy `.musesheet` still opens) | `SheetGrid` (native AppKit grid) | `sheet.set_cells` (81 functions) | Excel (`XLSXWriter`), CSV |
| Presentation | `.ottoslides` (`Presentation` JSON; legacy `.museslides` still opens) | `SlidesEditorView` + deck engine | `slides.guide`, `slides.set_deck`, `slides.set_theme`, `slides.add_slide`, `slides.update_slide`, `slides.delete_slide` | Editable PowerPoint (`PPTXWriter`), exact-look PowerPoint, PDF, single-file web page |

All three offer **Open in Google Docs/Sheets/Slides**: a Google-ready file saved to Downloads with
Google Drive opened. A one-click upload needs Otto's Google app registration first.

**Helpers stay beside the work.** Asking from a file or dashboard sends to a helper agent bound to
it (`OfficeStore.session(path:)`, `dashboard:<id>` keys). Bound helpers are hidden from Chat's
Sessions list, Chat never navigates to them, and standing tool instructions travel as hidden
per-turn context (`workBindingContext`) so the chat shows only what the person typed.

**Spreadsheet grid.** One `SheetCellsView` draws only visible cells. Typing edits in place;
`=` suggests functions (`SpreadsheetFunctions`); clicking or arrowing inserts references while the
formula accepts one (`SpreadsheetFormula.acceptsReference`), with ranges outlined; the grid never
takes the keyboard while a cell is being edited. Fill handle, ⌘D/⌘R, copy/paste with Excel and
Sheets (formulas shift like Excel inside Otto), undo/redo, resizable columns.

**Deck engine.** `Resources/Deck/deck.css` and `deck.js` render 1280×720 slides with themes or
brand tokens, motion, animated SVG charts, count-ups, cards, steps, tables and a 3D cube.
`DeckRenderer` builds pages, `DeckWebView` edits in place, `DeckSnapshotter` renders thumbnails
and exports off screen, and `DeckPresenter` presents full screen with native key handling. Agent
HTML is sanitised (`DeckHTML.sanitize`), and every agent change keeps a version in History.

## Testing

- Unit and flow tests: `HomeCardTests`, `HomeCardToolsTests`, `OfficeToolsTests`,
  `SpreadsheetTests`, `SheetGridTests`, `DeckPresenterTests`, `SlideKeysTests`.
- Visual checks are opt-in renders in `HomeBriefSnapshotTests` (`OTTO_HOME_SNAPSHOT_DIR`,
  optionally `OTTO_HOME_SNAPSHOT_WORKSPACE`, `OTTO_DECK_FILE`).
- Live agent checks use `EndToEndSeedTests` against an isolated app build with its own bundle id,
  `--memory-preview --workspace … --profiles-root …`. Always give such runs a kill switch and
  disable the seeded `* * * * *` automation after its first run: it fires every minute and each
  run is a real agent.
