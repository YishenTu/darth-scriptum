# DarthScriptum Development Instructions

## Project structure

Organize by target, then by domain:

```text
Sources/
  App/Documents/
  Core/Source/
  DesignSystem/
  Document/{Monitoring,Persistence,Recovery}/
  Document/Synchronization/{Contracts,Coordinator,Reducer}/
  Editor/{Compatibility,Composition,Presentation,Rendering,Web}/
  Editor/Composition/Resize/
  Workspace/
  Resources/
  Configuration/
Tests/
  Unit/{App,Core,DesignSystem,Document,Editor,Workspace,Fixtures}/
  E2E/
  Performance/
  Architecture/
scripts/
```

- Keep runtime assets in `Resources` and build-owned files in `Configuration`.
- Keep each domain's entry surface at its root and add subfolders only for durable responsibilities shared by multiple files.
- Mirror production paths in `Tests/Unit`; use `E2E`, `Performance`, `Unit/Fixtures`, and `Architecture` only for their named purposes.
- Do not create catch-all folders or files such as `Common`, `Shared`, `Utilities`, `Helpers`, `Extensions`, `Models`, or `Misc`. Do not create a folder for one file unless it is an architectural boundary.
- Keep scoped `AGENTS.md` files only at stable domain roots. Preserve Xcode groups, target membership, build settings, scripts, and test discovery during moves.

## Architecture rules

### Dependency direction

All sources currently compile into one application target. These rules govern which directories may reference types declared in other directories; they are not Swift module-import rules.

- `Core` and `DesignSystem` are leaf domains. Product domains may depend on them, but they must not depend on `App`, `Document`, `Editor`, or `Workspace`.
- `Document` may depend on `Core` and system I/O or concurrency frameworks. It must not depend on UI domains or renderer frameworks.
- `Editor` may depend on `Core`, `DesignSystem`, bundled `Resources`, and renderer frameworks. It must not depend on concrete synchronization, persistence, or recovery implementations.
- `Workspace` may depend on `Core`, the document coordinator entry surface and its source or status contracts, editor entry surfaces, and `DesignSystem`. It may issue document commands through the coordinator but must not depend on reducer, effect-executor, persistence, recovery, or renderer implementations.
- `App` is the composition root and may reference every runtime domain to adapt native lifecycle events and wire concrete dependencies. Domain policy must remain in the owning domain.
- `Workspace/MarkdownWindowController.swift` is the sole permitted lower-layer integration with the App-owned `MarkdownDocument` host. Keep that concrete reference isolated; no other workspace or lower-domain type may reference App types.
- `Resources` contain runtime data and `Configuration` contains build-owned data; neither is a source of runtime policy.

Reverse dependencies outside the explicit window-document integration are forbidden. Introduce new cross-domain calls through an owning domain's entry surface or contract rather than by referencing its implementation details.

### Ownership

- `App` owns application and `NSDocument` lifecycle integration, native callback adaptation, and concrete dependency wiring.
- `Core` owns dependency-light cross-domain values and algorithms. `MarkdownSourceBuffer` is the sole in-memory source and revision mutator.
- `DesignSystem` owns reusable colors, typography, materials, and other visual primitives, but no feature state or policy.
- `Document` owns file authority, persistence, recovery, and synchronization policy. `DocumentSyncReducer` is the sole synchronization transition authority.
- `Editor` owns editing composition, `EditorPaneModel` presentation state, native presentation, rendering, compatibility adaptation, and local WebKit lifecycle.
- `Workspace` owns window, pane identity and composition, tab, split, focus, shortcut, and workspace-restoration composition.

Only the owner may mutate owned state. Non-owners must request changes through the owner's public contract and must not retain independently mutable copies of that state. Coordination does not transfer ownership.

### State lifetimes

- Durable document bytes, file identity, commit evidence, and recovery records are owned by `Document` persistence and recovery components and may survive process restart.
- The live source and revision are owned by one `MarkdownSourceBuffer` for the document lifetime and are shared by every editor pane.
- Synchronization workflow state, epochs, and effect tokens are owned by the document reducer and coordinator for one document lifetime; stale or mismatched completions cannot mutate current state.
- Workspace state owns live window, pane composition, split, and focus. `EditorPaneModel` owns pane-local selection, scroll, position, and renderer association; a versioned workspace restoration snapshot may capture and recreate that presentation but is never source or synchronization authority.
- Editor view, observation, rendering-cache, and WebKit-session state is disposable and must be rebuilt from owned source, pane, and workspace composition state when recreated.

### Cross-domain invariants

- Split panes share one source buffer; layout, focus, restoration, and tab changes must not create another source authority or alter document lifecycle state.
- Only `MarkdownSourceBuffer` mutates source revisions, and only `DocumentSyncReducer` selects synchronization transitions.
- The coordinator applies events serially. Effect requests are immutable and complete, completions echo their full tokens, and stale tokens are rejected.
- Blocking file and recovery work crosses `DocumentFileAccess`; it never blocks the main actor or a Swift cooperative executor.
- Durable evidence is committed before corresponding in-memory success is published. Unproven attachment, commit, recovery, ownership, or cleanup safety fails closed.
- AppKit close and quit callbacks preserve refusal and cancellation and complete exactly once.
- Renderer inputs and document-derived resource requests remain untrusted and cannot widen file, navigation, window, network, or persistence authority.

## Naming

- Follow Swift API Design Guidelines. Use `UpperCamelCase` for types, protocols, Swift files, and directories; use `lowerCamelCase` for members and values; preserve established initialisms.
- Name files after their primary declaration and keep one primary top-level type per file. Use `Type+Capability.swift` for focused extensions; avoid generic or catch-all names.
- Choose precise roles: nouns for types and values, verbs for side effects, `make` for factories, assertion-style Booleans, `Error` errors, and `-able` capability protocols. Prefer role suffixes such as `Store`, `Coordinator`, or `Renderer` over vague names such as `Manager` or `Helper`.
- Use the narrowest truthful access level; preserve required and upstream names. Name repository shell scripts with lower-kebab-case verb phrases.

## Working notes

- Do not create or commit `docs/` content; it becomes stale quickly. Put temporary documentation, plans, and handoff notes in Git-ignored `.context/`.

## Tests

- TDD is mandatory.
- Name XCTest types and files `<Subject>Tests`; name methods `test<Action>When<Condition><Outcome>()`.
- Name support types by role: `Recorder`, `Spy`, `Stub`, `Fake`, `Harness`, or `Fixture`. Use `Mock` only when it verifies interactions.
- Name shared support files `<Subject>TestSupport.swift` or `<Purpose>TestHarness.swift`. Use lower-kebab-case for repository-owned non-Swift fixtures.

## Verification

- Restrict every macOS build and test to `arm64` and use the narrowest meaningful check.

### Routine development

- Run `./scripts/lint.sh` after Swift changes; it is a fast, non-compiling check.
- Prefer focused tests: `./scripts/test.sh <test-identifier> [...]`. Use `--unit` or `--e2e` for a complete suite, and `--all` explicitly for both non-performance suites.
- Before handing back production-code changes, run relevant tests and one Debug build with `./scripts/build-debug.sh`; skip the separate build when the test command already built every affected target.
- Use Xcode **Build** (`Command-B`) for interactive compilation. Routine scripts reuse repository-local `DerivedData/`.
- Run `./scripts/check-architecture.sh` after ownership, cross-domain dependency, or scoped-instruction changes.
- Documentation and instruction changes require no build unless they alter executable scripts, build commands, or project configuration.

### Runtime and UI

- Use Xcode **Run** (`Command-R`) only when behavior must be observed in the running app. A successful launch does not replace automated tests.

### Full verification

- Run `./scripts/verify.sh` only for broad or cross-domain changes; architecture, dependency, project, scheme, Release, or performance changes; release preparation; CI-equivalent validation; or an explicit user request.
- A normal commit does not require full verification. Packaging, installation, signing, notarization, and distribution require an explicit request.
- Report the checks run and any relevant checks intentionally skipped.
