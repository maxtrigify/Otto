# Images in bot and session replies

Agents can embed a saved screenshot or image using a standalone Markdown image:

```markdown
![Paper design preview](</absolute/path/to/Paper preview (1).png>)
```

The shared chat renderer supports absolute paths, local `file:` URLs, workspace-relative paths and HTTP(S) URLs. Click a preview to enlarge it; Done or Escape closes the viewer. Missing files retain a labelled placeholder.

When the runtime appends assistant prose, it copies local image references into `.otto/chat-attachments/replies` under the agent working directory and rewrites the stored transcript to the saved absolute path. Content hashes deduplicate identical bytes; replacing the source file creates a separate saved image. The stored reply survives deletion of the source screenshot. Existing historical replies render their original references but cannot recover files that are already gone.

Imports are limited to regular files of supported image extensions, up to 50 MB each. Images in fenced code examples are left alone. Failed imports retain the original reference. Remote images remain remote and are not archived. The managed attachment directory must be retained alongside the workspace.

A screenshot that exists only in a tool's image payload is not automatically attached. The provider bootstrap instructs agents to save/export the bytes to a file and explicitly embed that file in their reply. No provider transcript schema changes are required.

Validation: `scripts/otto-swift test --filter 'ChatImageStoreTests|MarkdownImageTests'`. Set `OTTO_IMAGE_SNAPSHOTS` to a directory to render the shared chat view at narrow and wide widths for visual inspection.
