# Editor boundary

- Own native presentation, editor composition, MarkdownEngine adaptation, rendering, and local WebKit lifecycle; see [the architecture](../../docs/architecture.md).
- Keep native text-view traversal and raw MarkdownEngine internal-key assumptions isolated in `compatibility/markdownenginecompatibility.swift`.
- Treat document and renderer input as untrusted: preserve vendored-local resources, exact file read roots, deny-by-default CSP, non-persistent storage, denied navigation/windows/network, and bounded teardown.
- Do not implement persistence, recovery, file synchronization, or reference their concrete types.
- Mirror each compatibility, composition, presentation, rendering, or web change in the matching `tests/editor/` boundary.
