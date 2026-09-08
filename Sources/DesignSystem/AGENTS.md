# Adaptive presentation

- Resolve appearance-sensitive layer colors under the view's effective appearance and refresh on appearance changes; cached `CGColor` values lose `NSColor`'s dynamic behavior.
- Materials must respond to window activation and Reduce Transparency changes. Preserve an opaque, appearance-correct fallback and release window observers when moving between windows. Verify these transitions in `AppThemeTests` when changing materials or theme colors.
