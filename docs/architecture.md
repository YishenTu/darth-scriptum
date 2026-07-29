# Architecture

## Status

This document records the intended ownership model for the industrial-grade
migration. It describes both current contracts and migration targets; a target
is not implemented merely because it appears here.

DarthScriptum remains one native macOS application target and one hosted test
bundle. Markdown source is the only canonical document state. Rendered output,
pane state, caches, and window state are disposable projections.

## Dependency direction

```text
app -> workspace, document, editor
workspace -> document, editor
document -> core
editor -> core, MarkdownEngine
```

- `core` owns source values, revisions, edits, snapshots, formats, identities,
  fingerprints, history, line indexing, and eventually `MarkdownSourceBuffer`.
  It never imports UI, WebKit, or MarkdownEngine frameworks.
- `document` owns codec, merge, durability, recovery, monitoring, and
  synchronization. It never owns UI or renderer work.
- `editor` owns native presentation, MarkdownEngine compatibility, and local
  rendering. It never owns persistence or synchronization.
- `workspace` composes panes, status, tabs, and split state. It does not do file
  I/O or renderer implementation.
- `app` owns application lifecycle, `NSDocument`, window construction, menus,
  and concrete dependency construction.

`scripts/check-architecture.sh` enforces the narrow folder rules above. It is a
guardrail, not a Swift parser or a replacement for code review. Run it from the
repository root, or use `--repo-root <fixture-root>` for isolated fixtures.

### Current ownership exceptions

The check currently documents exactly two migration exceptions:

- `src/document/markdownsourcebuffer.swift` remains document-owned until M1
  moves `MarkdownSourceBuffer` to `src/core`.
- `src/document/markdowndocument.swift` remains the AppKit composition adapter
  until M1 moves `MarkdownDocument` to `src/app/document`.

Both exceptions are removal gates, not permanent exemptions. The raw
MarkdownEngine internal-key rule becomes active when E1 adds
`src/editor/markdownenginecompatibility.swift`; current key use is intentionally
not moved during F1.

## Source and file authority

Only `MarkdownSourceBuffer` may mutate in-memory Markdown source and its
revision. Every editor mutation carries an expected revision and an origin.
Encoding, BOM, newline style, and final-newline behavior are part of the source
format and must be preserved whenever representable.

The durable baseline is authority for the last proven file bytes. A monitor
signal is an observation, never authority: synchronization reads the target,
compares identity, bytes, the durable baseline, and the local revision, then
chooses reload, save, merge, or recovery. It must fail closed rather than choose
between unprovably safe versions.

The migration target is a pure reducer with immutable effects and echoed
lifetime, attachment, and attempt tokens. Effect executors must not reread the
coordinator's mutable source, URL, identity, or baseline.

## Synchronization and recovery lifecycle

Current behavior is characterized in the integration tests: open/edit/autosave,
external reload, compatible merge, conflict recovery, Save As attachment,
managed close refusal, native untitled close delegation, native quit routing,
and split panes sharing one source.

The migration target is:

1. A coordinator serializes events and publishes a workspace-compatible status
   snapshot.
2. Save, read, merge, monitor, and recovery effects use complete immutable
   inputs and reject stale token results.
3. Recovery has explicit loading, ready, and failed states; one FIFO actor
   serializes cross-document persistence mutations.
4. Blocking disk work runs on a dedicated utility DispatchQueue boundary, not
   on the main actor or a Swift cooperative executor.

Migration target: managed files may close only after the latest revision and
required recovery bookkeeping are durably proven. Failure or deadline expiry
refuses closure. Untitled documents retain native `NSDocument`
Save/Cancel/Don't Save behavior. Any document refusal or user cancellation
aborts application termination.

## Renderer trust boundary

Renderer input is untrusted document content. Mermaid and MathJax use vendored
local resources, non-persistent WebKit storage, and no network authority.
The F2 migration target narrows main-frame navigation to the exact canonical
entry URL plus `about:blank`, constrains file read access to the vendored root,
denies new windows, and proves hostile pages make zero loopback requests.

MarkdownEngine is pinned at `0.10.1`. E1 will isolate native text-view traversal
and private attributed-string keys in one compatibility file. Do not add new
raw internal-key use elsewhere.

## Change guidance

Keep a change in the layer that owns its invariant. Add focused tests before
altering source authority, persistence, lifecycle, renderer policy, or
MarkdownEngine assumptions. Do not introduce a framework target, dependency
injection framework, generic event bus, service locator, renderer registry, or
generic cache without a separately approved design.
