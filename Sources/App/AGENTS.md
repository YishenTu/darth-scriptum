# App boundary

- Own application lifecycle, menus, `NSDocument`, window construction, AppKit callback adaptation, and concrete dependency wiring.
- Compose document, workspace, and editor contracts without moving synchronization, persistence, or renderer policy into this layer.
- Preserve native close and quit routing: translate AppKit callbacks to full reducer tokens, retain every refusal or cancellation, and complete each callback once.
- Verify app behavior in `Tests/Unit/App/` and close/quit behavior in `Tests/E2E/`.
