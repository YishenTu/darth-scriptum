# App boundary

## Ownership

- Own application lifecycle, menus, `NSDocument` host integration, window construction, AppKit callback adaptation, and concrete dependency wiring.
- Treat `MarkdownDocument` as a native lifecycle adapter around document-owned source, persistence, recovery, and synchronization contracts; it is not the synchronization policy owner.

## Dependencies and boundary

- As the composition root, App may reference every runtime domain to construct and connect concrete dependencies.
- Translate native events into document or workspace contract calls. Do not move synchronization, persistence, workspace, editor, or renderer policy into this layer.
- Lower domains must not reference App types except for the isolated `MarkdownWindowController` to `MarkdownDocument` integration permitted by the root architecture rules.

## State and invariants

- Retain native close and quit callbacks until the owning document lifecycle reaches a decision.
- Translate callbacks to full reducer tokens, preserve every refusal or cancellation, reject stale completions, and complete each callback exactly once.

## Verification

- Verify app behavior in `Tests/Unit/App/` and close or quit behavior in `Tests/E2E/`.
