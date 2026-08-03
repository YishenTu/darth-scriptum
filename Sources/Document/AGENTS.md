# Document boundary

## Ownership

- Own file authority, codecs, monitoring, merge, durability, recovery, and synchronization state.
- Keep `DocumentSyncReducer` as the sole synchronization policy and transition owner. The coordinator owns serialized event application; effect executors perform requested work without selecting policy.

## Dependencies and boundary

- Depend on Core source values and system I/O or concurrency frameworks.
- Expose source, status, lifecycle, and effect contracts without leaking concrete persistence or recovery implementations into UI domains.
- Do not import AppKit, SwiftUI, WebKit, or MarkdownEngine or reference App, Workspace, or Editor host types.
- Route every blocking document or recovery operation through `DocumentFileAccess`; never block the main actor or a Swift cooperative executor with file I/O.

## State and invariants

- Keep coordinator event application serialized and effect requests complete and immutable, with full tokens echoed on completion and stale tokens rejected.
- Treat attachment identity, durable baselines, commit generations, recovery records, cleanup receipts, and raw evidence as document-owned state.
- Fail closed when attachment, baseline, commit, recovery generation, record ownership, or cleanup safety is unproven; preserve raw evidence and durable-before-memory ordering.

## Verification

- Mirror changes under `Tests/Unit/Document/` and cover cross-layer lifecycle behavior in `Tests/E2E/`.
