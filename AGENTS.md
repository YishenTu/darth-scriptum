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
  {App,Core,DesignSystem,Document,Editor,Workspace}/
  {Integration,Performance,Fixtures,Architecture}/
scripts/
```

- `App` owns lifecycle and dependency wiring; `Core` owns dependency-light cross-domain values and algorithms; `DesignSystem` owns visual primitives.
- `Document` owns persistence and synchronization, `Editor` owns editing and rendering, and `Workspace` owns window, pane, focus, and shortcut composition.
- Keep runtime assets in `Resources` and build-owned files in `Configuration`.
- Keep each domain's entry surface at its root and add subfolders only for durable responsibilities shared by multiple files.
- Mirror production paths in `Tests`; use `Integration`, `Performance`, `Fixtures`, and `Architecture` only for their named purposes.
- Do not create catch-all folders or files such as `Common`, `Shared`, `Utilities`, `Helpers`, `Extensions`, `Models`, or `Misc`. Do not create a folder for one file unless it is an architectural boundary.
- Keep scoped `AGENTS.md` files only at stable domain roots. Preserve Xcode groups, target membership, build settings, scripts, and test discovery during moves.

## Naming

- Follow the Swift API Design Guidelines and optimize names for clarity at the call site.
- Use `UpperCamelCase` for targets, modules, types, protocols, generic parameters, Swift directories, and Swift filenames. Use `lowerCamelCase` for functions, properties, variables, parameters, enum cases, and constants.
- Name files after their primary declaration and keep one primary top-level type per file. Use `Type+Capability.swift` for focused extensions.
- Avoid generic filenames such as `Types.swift`, `Models.swift`, `Helpers.swift`, `Extensions.swift`, and `Constants.swift`.
- Use nouns for values and types. Name capability protocols with `-able`, `-ible`, or `-ing`; do not use an `I` prefix or unnecessary `Protocol` suffix.
- Use precise role suffixes such as `Store`, `Coordinator`, `Reducer`, `Renderer`, `Policy`, `Scheduler`, `Observer`, `Delegate`, `Factory`, or `Adapter`. Avoid vague `Manager`, `Helper`, `Util`, `Base`, and `Service` names.
- Use verbs for side effects, noun phrases for queries, `make` for factories, assertion-style Boolean names, and `Error` for error types. Do not restate `async` or `throws` in a name.
- Preserve Swift casing for initialisms and established names: `URLSession`, `documentURL`, `HTMLRenderer`, `UTF8`, `recordID`, `AppKit`, `SwiftUI`, `WebKit`, and `LaTeX`.
- Use the narrowest truthful access level. Preserve required or upstream names for `main.swift`, `Package.swift`, `Info.plist`, assets, generated files, and vendored files.
- Name repository shell scripts with lower-kebab-case verb phrases, such as `build-debug.sh`.

## Tests

- Name XCTest types and files `<Subject>Tests`; name methods `test<Action>When<Condition><Outcome>()`.
- Name support types by role: `Recorder`, `Spy`, `Stub`, `Fake`, `Harness`, or `Fixture`. Use `Mock` only when it verifies interactions.
- Name shared support files `<Subject>TestSupport.swift` or `<Purpose>TestHarness.swift`. Use lower-kebab-case for repository-owned non-Swift fixtures.

## Verification

- Restrict every macOS build and test to `arm64` and use the narrowest meaningful check.

### Routine development

- Run `./scripts/lint.sh` after Swift changes; it is a fast, non-compiling check.
- Prefer focused tests: `./scripts/test.sh <test-identifier> [...]`. Use `--all` explicitly for the complete non-performance suite.
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
