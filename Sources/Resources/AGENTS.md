# Renderer assets

- Keep renderer scripts/fonts local. Preserve deny-by-default CSP in HTML wrappers: no remote scripts/fonts, fetches, frames, workers, objects, or forms. Resource edits must not expand Editor's file/navigation policy.
- For upstream updates, reconcile package metadata, licenses, `THIRD_PARTY_NOTICES.md`, version assertions in `scripts/check-vendored-resources.sh`, and `scripts/vendor-checksums.sha256`. Verify upstream provenance before changing hashes; do not regenerate them merely to pass checks.
- Use `scripts/vendor-mermaid.sh` for Mermaid updates, changing its pinned version and archive/bundle hashes together. MathJax has no updater; verify replacements as dependency changes.
- Checksums cover upstream files; HTML/JS wrappers and MathJax config are repository-owned. Wrapper-only edits need no upstream version/license change. Bundle additions/removals require updating the exact allowlist in `scripts/check-vendored-resources.sh`; symlinks are forbidden.
- After renderer-bundle edits, run `./scripts/check-vendored-resources.sh`. For wrapper/security changes run `DarthScriptumUnitTests/LocalWebSecurityTests` and affected renderer tests through `./scripts/test.sh`; upstream dependency changes require full verification. App-icon-only changes need no renderer tests.
