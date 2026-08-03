# DesignSystem boundary

## Ownership

- Own reusable application colors, typography, materials, spacing, and other visual primitives.
- Keep primitives feature-independent and suitable for use by App, Editor, and Workspace presentation.

## Dependencies and boundary

- Depend only on platform presentation frameworks such as AppKit and SwiftUI.
- Do not reference App, Core, Document, Editor, or Workspace types; import renderer frameworks; perform file or network I/O; or acquire feature policy.
- Consumers choose when and why to apply a primitive. DesignSystem defines its visual meaning but does not coordinate feature behavior.

## State and invariants

- Keep primitives stateless or limited to view-local presentation state.
- Do not retain document content, synchronization state, editor lifecycle state, or workspace navigation state.

## Verification

- Verify visual primitive behavior in `Tests/Unit/DesignSystem/` and run the architecture guard after boundary changes.
