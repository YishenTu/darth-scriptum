# Editing and rendering constraints

- Keep native text-view traversal in the compatibility adapter and raw MarkdownEngine attribute-key assumptions in `Compatibility/MarkdownEngineCompatibility.swift`. Engine upgrades require compatibility tests and affected rendering checks; compilation does not establish compatibility with internals.
- Keep native text-view undo disabled; route undo/redo to the source buffer's history.
- Mirror source-authorized peer edits only when prior native presentation and the exact transition are proven. Display transformations, smart-input-sensitive edits, and ambiguous state require a full binding rebuild. Mirroring must never publish another source mutation.
- Preserve selection/viewport through `EditorPaneModel` when rebuilding native views. Tear down view-owned observations/tasks without disposing rendering services still shared by another pane.
- WebKit rendering uses vendored resources, an exact canonical bundle read root, deny-by-default CSP, non-persistent storage, and bounded teardown. Permit only the entry/blank navigation allowed by `LocalWebResourcePolicy`; deny other navigation, new windows, and network access.
- Image loading/watching must use the same authorized file request. Preserve descriptor-based containment, symlink-race protection, load/cache bounds, and rejection of completions from obsolete roots or disposed providers. A URL-prefix check alone is insufficient file authority.
