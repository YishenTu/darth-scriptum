# Workspace boundary

## Ownership

- Own status presentation, pane identity and composition, window, tab, split, focus, shortcut, and workspace-restoration composition.
- Capture and restore Editor-owned `EditorPaneModel` presentation state without becoming its independent authority. Do not own document source, synchronization policy, persistence, or editor renderer internals.

## Dependencies and boundary

- Depend on Core values, the document coordinator entry surface and its source or status contracts, Editor entry surfaces, and DesignSystem primitives.
- `MarkdownWindowController.swift` may integrate with the App-owned `MarkdownDocument` host at the native document-window boundary. Keep this as the sole concrete App reference in Workspace.
- Issue document lifecycle and recovery commands through the coordinator. Do not reimplement or directly depend on reducers, effect executors, persistence, recovery storage, file access, or renderer internals.

## State and invariants

- Preserve one `MarkdownSourceBuffer` shared across split panes; pane models and native views must not become independent source authorities.
- Keep selection, viewport, focus, split, and other presentation state pane-local. A restoration snapshot may recreate this state but never owns document content or synchronization state.
- Layout, focus, restoration, and tab operations must not implicitly attach, save, recover, close, or otherwise transition the document lifecycle.

## Verification

- Verify Workspace changes in `Tests/Unit/Workspace/` and shared-source or document-window behavior in the relevant E2E tests.
