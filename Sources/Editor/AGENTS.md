# Editor boundary

## Ownership

- Own native presentation, editor composition, `EditorPaneModel` presentation state, MarkdownEngine adaptation, rendering, and local WebKit lifecycle.
- Own native-view observations and disposable rendering state, but not document source, synchronization state, or workspace navigation state.

## Dependencies and boundary

- Depend on Core source contracts, DesignSystem primitives, bundled Resources, and renderer frameworks through Editor-owned adapters.
- Do not implement persistence, recovery, or file synchronization or reference their concrete types.
- Keep native text-view traversal and raw MarkdownEngine internal-key assumptions isolated in `Compatibility/MarkdownEngineCompatibility.swift`.
- Treat document and renderer input as untrusted: preserve vendored-local resources, exact file read roots, deny-by-default CSP, non-persistent storage, denied navigation, windows, and network, and bounded teardown.

## State and invariants

- Submit edits through `MarkdownSourceBuffer` and rebuild presentation from its owned revision; never keep an independently mutable document source.
- Keep native text-view undo disabled; document undo and redo belong exclusively to `MarkdownSourceBuffer`.
- Mirror source-authorized peer edits through the compatibility adapter only when the prior native presentation and exact transition are proven. Display transformations, smart-input-sensitive edits, and ambiguous state must fall back to a full binding rebuild, and mirroring must never publish another source mutation.
- Keep native selection and viewport state synchronized through `EditorPaneModel`; Workspace may capture or restore that model through its exposed state but must not create a second pane-state authority.
- Tear down observations, tasks, renderer sessions, caches, and WebKit state within their owning editor lifecycle.

## Verification

- Mirror each compatibility, composition, presentation, rendering, or web change in the matching `Tests/Unit/Editor/` boundary.
