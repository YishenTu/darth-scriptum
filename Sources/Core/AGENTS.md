# Core boundary

## Ownership

- Own canonical source values, revisions, edits, formats, identities, fingerprints, history, line indexing, and `MarkdownSourceBuffer`.
- Keep `MarkdownSourceBuffer` as the sole in-memory source and revision authority for a document.

## Dependencies and boundary

- Depend only on dependency-light system frameworks such as Foundation, Combine, and CryptoKit.
- Do not import UI, WebKit, or MarkdownEngine frameworks, perform file I/O, or reference App, Workspace, Document-host, or Editor types.
- Expose values and algorithms without acquiring lifecycle, persistence, presentation, or feature policy.

## State and invariants

- All source mutations pass through `MarkdownSourceBuffer`; non-owners may observe it or request edits but must not maintain another mutable source revision.
- Preserve expected-revision validation, monotonic revision history, change-origin semantics, and deterministic source transformations.

## Verification

- Verify Core changes in the matching `Tests/Unit/Core/` files and run the architecture guard.
