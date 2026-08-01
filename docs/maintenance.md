# Maintenance

Run commands in this document from the repository root.

## Verification

The architecture guard requires `rg` (ripgrep), fails closed when it cannot
inspect the tree, and has its own fixture suite:

```sh
./scripts/check-architecture.sh
tests/architecture/run-tests.sh
```

During a narrow change, run the owning test class. This example exercises the
document synchronization reducer:

```sh
xcodebuild \
  -project DarthScriptum.xcodeproj \
  -scheme DarthScriptum \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:DarthScriptumTests/DocumentSyncReducerTests \
  test
```

Every code change must finish with the repository-local Debug build:

```sh
xcodebuild \
  -project DarthScriptum.xcodeproj \
  -scheme DarthScriptum \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For a broad change or before committing a completed implementation, run:

```sh
./scripts/verify.sh
git diff --check
```

`verify.sh` uses temporary Derived Data, builds Debug and Release, runs the
non-performance suite in Debug, and runs `PerformanceTests` under the optimized
Benchmark configuration. It does not launch or install the application.

The tracked GitHub Actions workflow runs for pull requests and pushes to
`main`. It uses `macos-26`, Xcode 26.4, arm64, read-only repository
permissions, locked package resolution, the architecture and whitespace
checks, Debug and Release builds, and the non-performance suite. It uploads the
test result bundle only on failure. The optimized performance suite remains a
local `verify.sh` responsibility.

## Dependency and license updates

The application dependency is exact-pinned in the Xcode project, with the full
resolved graph recorded by SwiftPM. Audit the current pin with:

```sh
rg -n 'swift-markdown-engine|0\.11\.0' \
  DarthScriptum.xcodeproj/project.pbxproj \
  DarthScriptum.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

For a MarkdownEngine update:

1. Review the upstream release and license changes, then update the exact
   requirement intentionally. Never move the pin as part of unrelated work.
2. Resolve and inspect the complete graph:

   ```sh
   xcodebuild \
     -project DarthScriptum.xcodeproj \
     -scheme DarthScriptum \
     -resolvePackageDependencies
   git diff -- \
     DarthScriptum.xcodeproj/project.pbxproj \
     DarthScriptum.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
   ```

3. Keep all native-view traversal and internal-key assumptions in
   `src/editor/compatibility/markdownenginecompatibility.swift`. Prefer an
   upstream public API and remove a superseded shim in the same change.
4. Run `MarkdownEngineCompatibilityTests`, the editor suites, the architecture
   guard, and full verification. Manually validate live/source mode, selection,
   split panes, images, Mermaid, inline and display TeX, and large-file
   fallback.
5. Update [Third-Party Notices](../THIRD_PARTY_NOTICES.md) if the dependency,
   attribution, bundled code, or license terms changed.

DarthScriptum itself is distributed under [MIT](../LICENSE). Vendored
components retain their own terms. Their current versions, source locations,
and license paths are recorded in
[Third-Party Notices](../THIRD_PARTY_NOTICES.md); the copied license texts live
beside the corresponding bundles.

## Vendored renderer updates

The renderer versions and security declarations are directly inspectable:

```sh
rg -n '"version"|Content-Security-Policy|connect-src' \
  src/resources/{MathJax,Mermaid}.bundle/package.json \
  src/resources/{MathJax,Mermaid}.bundle/*-renderer.html
```

`scripts/vendor-mermaid.sh` is the reproducible Mermaid updater. A Mermaid
upgrade must update its version, archive checksum, and bundle checksum
together, run the script, review the resulting `package.json`, bundle, and
license, and update `THIRD_PARTY_NOTICES.md`.

MathJax has no repository updater script. Replace its bundle only as an
explicitly reviewed dependency change, recording the upstream release URL,
version, artifact checksum, copied files, and license provenance in the change.
Keep `src/resources/MathJax.bundle/package.json`, its `LICENSE`, and
`THIRD_PARTY_NOTICES.md` aligned.

For either renderer:

- preserve the deny-by-default CSP and exact local bundle read root;
- do not add remote scripts, fonts, fetches, frames, broad file access, new
  windows, or persistent WebKit storage;
- run `LocalWebSecurityTests` and the matching renderer tests, followed by full
  verification; and
- inspect generated or minified diffs for unexpected network endpoints and
  licensing changes instead of treating them as opaque output.

## Scoped agent guidance

The root `AGENTS.md` applies repository-wide. Concise local deltas exist only
at the stable boundaries `src/app/`, `src/core/`, `src/document/`,
`src/editor/`, `src/workspace/`, `src/resources/`, and `tests/`.

Codex discovers `AGENTS.md` from the working-directory ancestry, not from the
path of a file being edited. Start a worker in the relevant boundary directory,
or explicitly read the root file and every applicable scoped file before
editing there. Each sibling `CLAUDE.md` is only the one-line companion
`@AGENTS.md`; it does not replace Codex's `AGENTS.md` discovery.

Do not add another scoped pair unless that directory has a durable, materially
different local rule that its nearest parent does not already state.

## Archive, signing, and release

The repository defines a Release build and Xcode archive action, but it does
not promise unsigned distribution or implement signing, notarization, or
publication automation. Those operations require separate authorization,
credentials, and an identified release owner.

Before an authorized release:

1. Select a revision whose architecture checks, full local verification, and
   hosted verification are green.
2. Confirm `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, the supported macOS
   version, package pins, vendored versions, and all license notices.
3. Confirm the signing identity, entitlements, hardened-runtime result,
   notarization process, distribution channel, and credential handling without
   committing secrets.
4. Manually exercise open, edit, autosave, external change, conflict recovery,
   Save As, managed and untitled close, multi-document quit, split panes,
   Mermaid, and TeX on the release candidate.
5. Record artifact identity and checksums, verification evidence, publication
   authority, monitoring owner, and the rollback revision before publishing.

## Rollback

1. Stop publication and retain the failed artifact, logs, and result bundles.
2. Identify the last verified revision and the affected user-visible,
   persistence, recovery, renderer, dependency, and license contracts.
3. Revert only the approved release change. Do not delete or rewrite user
   documents, recovery stores, or commit-recovery evidence to make a rollback
   appear clean.
4. Restore dependency and vendored-asset pins together with their resolved
   graph, notices, licenses, and integrity metadata.
5. Re-run the architecture checks, focused regression tests, full verification,
   and release-candidate manual checks before republishing.
6. Record the incident, recovery compatibility, owner, and follow-up action.
