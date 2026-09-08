# Source contracts

- Keep source operations free of file I/O and document lifecycle or presentation policy.
- Edit/selection offsets use UTF-16 (`NSRange`/`NSString`), not Swift character counts. Reject stale expected revisions and ranges splitting surrogate pairs; cover non-BMP and combining-character cases when changing range transforms.
- Undo/redo share one history across panes. Preserve change origins and external-replacement history invalidation so synchronization and native dirty-state adaptation distinguish local edits, undo/redo, and reloads.
- Prepared metrics/indexes must describe the exact revision being installed. Preserve stale-result rejection and deferred indexing for large documents instead of adding unconditional whole-document scans on the main actor.
