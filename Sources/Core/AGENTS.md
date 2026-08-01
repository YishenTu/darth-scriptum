# Core boundary

- Own canonical source values, revisions, edits, formats, identities, fingerprints, history, line indexing, and `MarkdownSourceBuffer`.
- Keep `MarkdownSourceBuffer` as the only in-memory source and revision mutator; preserve expected-revision and change-origin semantics.
- Do not import UI, WebKit, or MarkdownEngine frameworks, perform file I/O, or reference app, workspace, document-host, or editor types.
- Verify core changes in the matching `Tests/Core/` files and run the architecture guard.
