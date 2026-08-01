# Document boundary

- Own file authority, codecs, monitoring, merge, durability, recovery, and synchronization.
- Keep the reducer as the sole synchronization policy owner, coordinator event application serialized, and effect requests complete and immutable with full tokens echoed on completion.
- Route every blocking document or recovery operation through `DocumentFileAccess`; never block the main actor or a Swift cooperative executor with file I/O.
- Fail closed when attachment, baseline, commit, recovery generation, record ownership, or cleanup safety is unproven; preserve raw evidence and durable-before-memory ordering.
- Do not import AppKit, SwiftUI, WebKit, or MarkdownEngine or reference app, workspace, or editor host types.
- Mirror changes under `Tests/Document/` and cover cross-layer lifecycle behavior in `Tests/Integration/`.
