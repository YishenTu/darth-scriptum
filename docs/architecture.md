# Architecture

## System shape

DarthScriptum is one native macOS application target and one hosted XCTest
bundle. The Xcode project uses file-system synchronized groups for `src/` and
`tests/`, so production and test membership follows the repository layout.
Repository guidance files such as `AGENTS.md` and `CLAUDE.md` are build
metadata, not application resources, and must remain excluded from product
copy phases.

Markdown source is the only canonical document content. Rendered output,
selection and pane state, caches, status text, tabs, and windows are disposable
projections of that source and the synchronization state.

## Dependency direction and ownership

```text
app --------> workspace --------> editor --------> resources
 |                |                  |
 |                +----> document    +----> core
 |                         |
 +-------------------------+----> core

workspace, editor --------> design-system
editor -------------------> MarkdownEngine
```

- `src/core/` owns source revisions, edits, snapshots, text formats, document
  identities, fingerprints, history, line indexing, and
  `MarkdownSourceBuffer`. It has no UI, renderer, or file-I/O responsibility.
- `src/document/` owns codecs, merge decisions, monitoring, durable commits,
  recovery, synchronization state, and effect execution. It does not own UI or
  renderer behavior.
- `src/editor/` owns native editor presentation, MarkdownEngine compatibility,
  Mermaid and TeX presentation, renderer lifecycle, and local WebKit policy. It
  does not own persistence or synchronization.
- `src/workspace/` composes pane, status, tab, split, and window behavior from
  document and editor contracts. It does not implement file access or
  rendering.
- `src/app/` owns `NSApplication` lifecycle, menus, `NSDocument`, AppKit
  callback adaptation, and concrete dependency construction.
- `src/design-system/` owns shared visual tokens and material behavior.
- `src/resources/` contains application assets and the vendored local renderer
  bundles consumed by the editor.

`scripts/check-architecture.sh` enforces the most important dependency and
ownership exclusions. It is a guardrail rather than a Swift parser or a
substitute for review. The check also rejects the former locations of
`MarkdownSourceBuffer` and `MarkdownDocument`.

The principal ownership entry points are:

- `src/core/markdownsourcebuffer.swift`
- `src/app/document/markdowndocument.swift`
- `src/document/synchronization/reducer/documentsyncreducer.swift`
- `src/editor/compatibility/markdownenginecompatibility.swift`
- `src/editor/web/localwebresourcepolicy.swift`

## Source and file authority

`MarkdownSourceBuffer` is the only in-memory Markdown source mutator. It owns
the monotonically advancing `SourceRevision`, edit history, undo/redo, and line
index. Editor changes carry an expected revision and a change origin; stale
changes cannot silently replace newer source.

`TextFileFormat` is part of a document snapshot. Decoding records the encoding,
byte-order mark, newline style, and final-newline behavior, and encoding
preserves them when the format can represent the source.

For an attached file, `DocumentSyncDurableBaseline` is the authority for the
last file bytes proven durable. It binds the snapshot and source revision to
the canonical document identity, target URL, and fingerprint. A file-monitor
signal is only an observation. The synchronizer reads and verifies the target
before deciding that it is unchanged, externally advanced, mergeable, missing,
or unsafe.

`DocumentFileAccess` is the sole execution boundary for blocking document and
recovery I/O. Its dedicated utility queue keeps Foundation file reads and
Darwin durability calls off both the main actor and Swift's cooperative
executor. `SafeFileCommitter` and the commit-recovery journal preserve the
preimage when a replacement outcome cannot otherwise be proven. An ambiguous
commit is reconciled from fresh immutable evidence; it is never assumed to
have succeeded.

## Reducer, effects, and tokens

`DocumentSyncReducer` is the sole synchronization decision owner. It is a pure
event reducer: each input `DocumentSyncState` and `DocumentSyncEvent` produces a
new state plus typed `DocumentSyncEffect` values. Focused reducer extensions
separate save, external merge, attachment, recovery, and close transitions
without creating additional policy owners.

The main-actor `DocumentSyncCoordinator` serializes queued events, applies
reducer transitions, executes effects, and publishes a narrow status projection
for the workspace. Effect executors receive complete immutable requests. They
must not reread mutable coordinator, host, source-buffer, attachment, or status
state.

Every asynchronous operation echoes a `SyncEffectToken` containing the
document lifetime, attachment epoch, operation kind, and attempt number. The
reducer rejects late or mismatched completions. A prepared save additionally
binds the exact source revision, encoded bytes, content fingerprint, expected
durable state, target, and commit generation into one capability.

## Recovery lifecycle

Recovery startup is an explicit state: loading, ready with a durable generation,
or failed with a typed issue. Source editing remains available while recovery
loads, but automated writes, unsafe reconciliation, and managed close cannot
advance without the required recovery evidence.

`SessionRecoveryStore` is the only mutable recovery-index owner. One actor-wide
FIFO drain serializes startup and all cross-document load, persist, migrate,
discard, and reconcile commands. Disk success precedes both mutation receipts
and in-memory generation changes.

Malformed data, unsupported schemas, unreadable journals, interrupted
mutations, unknown destination records, and unowned cleanup targets fail
closed. Raw evidence is preserved for retry. Recovery records move or disappear
only through generation-checked commands that carry the complete expected
record set; a save may discard only the exact cleanup target that its reducer
transition proved safe.

An external observation already queued for an attachment reaches a terminal
result before a local write begins. This ordering prevents a stale local save
from bypassing an observed external change.

## Close and quit

Managed-file close is a reducer operation, not an AppKit dirty-flag shortcut.
Close is allowed only after the current source revision is durably represented
and required recovery bookkeeping has completed. A save, recovery, monitor, or
deadline failure refuses close, and every close waiter is completed exactly
once.

Untitled documents continue through native `NSDocument` review, including
Save, Cancel, and Don't Save. The application uses the native
`NSApplication.terminate(_:)` path, so multi-document quit retains each
document's close decision: any managed refusal or native cancellation aborts
termination rather than forcing documents closed.

## Renderer trust boundary

Markdown and renderer input is untrusted document content. Native presentation
uses MarkdownEngine `0.11.0`; all native text-view traversal and raw
MarkdownEngine internal attributed-string keys are isolated in
`src/editor/compatibility/markdownenginecompatibility.swift`.

Mermaid and MathJax execute from their vendored bundles in `src/resources/`.
Their shared WebKit session uses a non-persistent data store, allows file reads
only beneath the canonical bundle root, permits main-frame navigation only to
the exact canonical entry URL or `about:blank`, rejects subframe navigation,
denies new windows, and replaces failed or timed-out web processes.

Each renderer entry page has a deny-by-default content security policy with no
network connection, remote script, frame, worker, object, form, or base-URL
authority. Security tests exercise hostile local content against a loopback
listener and require zero requests.

## Changing a boundary

Keep a change in the layer that owns its invariant and mirror it under
`tests/`. Add focused coverage before changing source authority, persistence,
recovery, lifecycle, renderer policy, or MarkdownEngine assumptions. Run the
architecture guard and the verification appropriate to the change as described
in [Maintenance](maintenance.md).
