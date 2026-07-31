# App boundary

- Own application lifecycle, menus, `NSDocument`, window construction, AppKit callback adaptation, and concrete dependency wiring; see [the architecture](../../docs/architecture.md).
- Compose document, workspace, and editor contracts without moving synchronization, persistence, or renderer policy into this layer.
- Preserve native close and quit routing: translate AppKit callbacks to full reducer tokens, retain every refusal or cancellation, and complete each callback once.
- Verify app behavior in `tests/app/` and close/quit behavior in `tests/integration/`.
