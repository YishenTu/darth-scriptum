# Pane composition and restoration

- Keep split, active-pane focus, source mode, and font size in `WorkspaceModel`; selection/viewport belong to each `EditorPaneModel`. A hidden secondary pane must not remain the active edit/shortcut target.
- Shared rendering services keep the two panes' caches and notifications coherent. Limit Workspace integration to construction, document-root updates, and lifetime management through Editor APIs; rendering/resource/cache policy stays in Editor. Hiding or rebuilding one pane must not dispose services used by the other.
- Layout, focus, restoration, and tab operations must not implicitly attach, save, recover, or close the document. Explicit lifecycle/recovery commands go through the coordinator.
- Treat restoration archives as untrusted presentation data: preserve version checks, finite/bounded coordinates, valid selections, and active-pane/split consistency. Clamp restored positions to current source when applying them to views; never restore document bytes or synchronization state from workspace archives.
