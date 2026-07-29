# Maintenance

## Verification

Run the architecture guard before handing off a boundary change:

```sh
./scripts/check-architecture.sh
```

The guard requires `rg` (ripgrep) and fails closed when it cannot inspect the
source tree.

Run focused tests while changing a narrow behavior. Build the Debug app into
repository-local Derived Data before handoff:

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

For broad changes or a completed implementation phase, run:

```sh
./scripts/verify.sh
```

That workflow builds Debug and Release, runs non-performance tests, then runs
the optimized Benchmark suite. Do not launch the app merely to validate a
command-line build.

## CI migration target

F3 will add the tracked CI workflow. Its target contract is `macos-26`,
`/Applications/Xcode_26.4.app/Contents/Developer`, arm64 builds, read-only
permissions, package resolution, the architecture check, Debug and Release
builds, non-performance tests, `git diff --check`, and failure-only result
artifacts. Until a clean hosted run proves that combination, this remains a
migration target rather than an operational guarantee.

## MarkdownEngine updates

`swift-markdown-engine` remains pinned at `0.10.1`. Before proposing an update:

1. Record the proposed pin and upstream change rationale.
2. Run the compatibility suite and focused editor tests.
3. Manually validate live/source mode, selection, split panes, images,
   Mermaid, inline/display TeX, and large-file fallback.
4. Prefer a newly available public API and remove any superseded compatibility
   shim in the same change.

Never change the pin as a side effect of unrelated work.

## Vendored renderer assets

For MathJax, Mermaid, or related JavaScript updates, record upstream version,
source URL, license, and integrity/provenance in the change. Recheck CSP and
local-only resource policy, then run renderer security and behavior tests. Do
not add remote scripts, fonts, fetches, frames, broad file roots, or persistent
WebKit storage to make an update work.

## Archive, signing, and release

Release operations require separate authorization and credentials. Before an
archive, confirm version/build numbers, license notices, verification evidence,
signing identity, notarization requirements, and rollback ownership. This
repository does not create or use signing secrets during ordinary development.

## Rollback checklist

1. Stop publication and retain the failed build/result artifacts.
2. Identify the last verified revision and the affected user-visible contract.
3. Revert only the approved change; preserve user work and recovery data.
4. Re-run architecture, focused, and required build verification.
5. Record the incident and the recovery/compatibility impact before retrying.
