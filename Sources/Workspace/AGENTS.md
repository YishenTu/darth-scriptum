# Workspace boundary

- Own status, pane, window, tab, split, focus, and shortcut composition.
- Consume document status and source contracts and editor views without reimplementing synchronization, persistence, file access, or renderer internals.
- Preserve one shared source across split panes and keep pane-local selection and presentation state disposable.
- Verify workspace changes in `Tests/Unit/Workspace/` and shared-source behavior in the relevant E2E tests.
