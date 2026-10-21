# Memory explorer

Memory opens in Explore: a local, interactive graph of the existing memory stores.
Manage retains budget meters, review queues and explicit curation controls.

## Recorded relationships

| Link | Evidence |
| --- | --- |
| In layer | Project/bot scope, or personal/operating compact context |
| Mentions | A saved entity ID |
| Tagged | A saved tag; not a claim of semantic similarity |
| Cites | A saved source ID; exact same-scope memory IDs link directly |
| Replaces | A saved supersedes ID, when that record is in the view |

No model calls, embeddings, inferred links, writes or trust changes occur while browsing.
Graph IDs include scope and bot identity, so same-named private records stay distinct.
The graph is displayed to the local user inside the inspector; it is not an agent retrieval API.

## Explore

- Search, choose a memory layer, toggle relationship types, or include activity/history in Filters.
- Select a dot or a row in List to read the memory and follow typed connections.
- Drag dots to rearrange them; drag the background to pan; pinch or use +/- to zoom.
- Focus connections isolates the selection and its immediate neighbors; Fit resets the view.
- Switching to Manage and back preserves your search, selection, filters and camera position.
- Solid memory dots are confirmed; hollow dots remain unconfirmed. History shows status badges.

The default projection samples up to 100 matching memories and 320 total nodes. Counts and a
sampling label make omissions visible. Search filters the full collection before sampling.
Activity logs and archived/replaced/expired records are initially excluded; Filters includes them.
Layout is deterministic, computed off the UI thread, and never changes persisted memory.

The native SwiftUI drawing API is used for graph lines; this does not restore the retired
spatial workspace, widgets, layout tools or any obsolete canvas product APIs.
