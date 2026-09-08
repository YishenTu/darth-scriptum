# DarthScriptum development

## Boundaries and ownership

All production Swift sources compile into one application target. These directory-level contracts are not enforced by compilation. Local constraints live in each domain's `AGENTS.md`.

| Scope | Authority | Allowed dependencies |
| --- | --- | --- |
| `Sources/Core` | Live source, revisions, source algorithms | Dependency-light system frameworks such as Foundation, Combine, CryptoKit; no UI, renderer, or product domains |
| `Sources/DesignSystem` | Feature-independent visual primitives | Platform presentation frameworks; no other source domains or renderer frameworks |
| `Sources/Document` | File authority, persistence, recovery, synchronization | Core and system I/O/concurrency frameworks; no UI or renderer frameworks |
| `Sources/Editor` | Pane presentation, editing composition, rendering, compatibility, WebKit sessions | Core, DesignSystem, Resources, renderer frameworks; no concrete document synchronization, persistence, or recovery |
| `Sources/Workspace` | Windows, tabs, splits, focus, shortcuts, restoration | Core, document coordinator and source/status contracts, Editor entry surfaces, DesignSystem |
| `Sources/App` | Native application/document lifecycle and dependency wiring | All runtime domains; feature policy stays with its owner |

- `MarkdownSourceBuffer` is the sole live source/revision authority for a document, shared by every pane. `DocumentSyncReducer` is the sole synchronization transition authority. Request mutations through these owners; presentation and restoration must not become additional authorities.
- `EditorPaneModel` owns pane selection, viewport, position, and renderer association. Views, observations, caches, and WebKit sessions are disposable; recreate them from owned source and presentation state.
- Workspace must not reference reducer, effect-executor, persistence, or recovery implementations. Two integration exceptions are scoped: `MarkdownWindowController.swift` may reference App's `MarkdownDocument`; `WorkspaceModel.swift` may construct and share Editor rendering services for its panes. Neither exception transfers domain policy to Workspace.
- Renderer inputs and document-derived resource requests are untrusted and must not widen file, navigation, window, network, or persistence authority.

## Placement and project integration

- Organize sources by domain and durable responsibility. Keep runtime assets in `Sources/Resources` and build-owned files in `Sources/Configuration`. Avoid catch-all directories (`Common`, `Shared`, `Utilities`, `Models`) and one-file directories without an architectural boundary.
- Mirror production responsibilities under `Tests/Unit`; cross-domain behavior belongs in `Tests/E2E`, performance tests in `Tests/Performance`, and shell architecture fixtures in `Tests/Architecture`.
- Xcode uses filesystem-synchronized groups: new Swift files under `Sources` or a test suite automatically join that target. Do not add redundant file/build-phase entries. Non-code files under `Sources` may need membership exclusions in `DarthScriptum.xcodeproj/project.pbxproj`.
- Keep scoped guides at domain roots and `Tests`. Adding/moving/removing guides requires reconciling the allowlist in `scripts/check-architecture.sh`, its fixtures, and Xcode membership exclusions. Each guide needs a sibling `CLAUDE.md` containing only `@AGENTS.md` and a terminal newline.
- Do not create or commit `docs/` content. Keep temporary plans and handoffs in gitignored `.context/`.

## Development and verification

- TDD is required for behavior changes: establish a failing regression or feature test before changing production behavior. Instruction-only edits use the instruction checks below, not new XCTest coverage.
- Restrict macOS builds/tests to `arm64`. Repository scripts apply `Sources/Configuration/Verification.xcconfig`, disable signing, and honor the checked-in SwiftPM resolution. Do not refresh dependency pins merely to resolve a local build failure.
- After Swift changes, run `./scripts/lint.sh` and relevant tests. Focused selectors require the target: `./scripts/test.sh DarthScriptumUnitTests/MarkdownSourceBufferTests` (optionally append a method). `--unit` and `--e2e` run their suites; `--all` runs both, excluding performance.
- Run `./scripts/build-debug.sh` before handing back production changes unless tests already built every affected target. Routine builds/tests reuse `DerivedData/`. Use Xcode Build for interactive compilation and Run when runtime observation is needed.
- For dependency/ownership or scoped-instruction changes, run `./scripts/check-architecture.sh` and `Tests/Architecture/run-tests.sh`. Instruction-only edits need no macOS build unless they alter scripts, build commands, or project configuration.
- Use `./scripts/verify.sh` for broad code changes, architecture/dependency/project/scheme changes, Release/performance changes, release preparation, or explicit full validation. It includes Debug/Release builds and all three test suites. Editorial instruction changes use the checks above; a normal commit alone does not require full verification.
- Packaging, installation, signing, notarization, and distribution require an explicit request. Report checks run and relevant checks skipped.
