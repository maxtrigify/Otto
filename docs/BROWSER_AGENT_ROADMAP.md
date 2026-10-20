# Otto agent browser roadmap

## Shipped foundation

- Otto-owned persistent browser profile and importable bookmarks.
- Renderer-neutral semantic inspection and revision-safe interaction.
- Resilient element resolution by stable ID or exact accessible name.
- Consequence-aware confirmation: navigation is fluid; commitments pause.
- Visible agent-control aura with reduced-motion support.
- Live activity and evidence ledger, bounded to the latest 40 entries.
- Automatic Build Mode for localhost and loopback pages.
- One-click semantic inspection and screenshot evidence in Build Mode.
- Page-load, JavaScript, promise-rejection, interaction and inspection failures in the ledger.

## Next product slice: select to fix

1. Add a user-controlled element selection overlay.
2. Capture element bounds, accessibility name, computed style, route and screenshot crop.
3. Resolve source locations from source maps when the inspected page is localhost.
4. Create a typed coding-agent task from the selection and comment.
5. Return to the same route and verify the changed region after hot reload.

## Verification contracts

- Allow tasks to declare routes, viewports and expected outcomes.
- Capture before/after screenshots, console state and interaction receipts.
- Require evidence before an agent reports a visual task complete.
- Present a compact pass/fail card on the canvas with replayable details.

## Session branches

- Fork tabs, cookies and storage into temporary task profiles.
- Let agents test mobile, authentication and accessibility independently.
- Merge evidence, never mutable browser state, back into the primary session.
- Make every branch disposable and visibly scoped to its owning agent.

## Permission membrane

- Remember read/navigation permission by domain.
- Separate draft entry from submission.
- Protect credential, payment and identity fields with human takeover.
- Pause page observation while the user enters protected information.
- Treat page content and diagnostics as untrusted data throughout.
