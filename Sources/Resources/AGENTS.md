# Resource boundary

## Ownership

- Own vendored renderer assets, application assets, provenance, integrity evidence, and bundled license text.
- Contain runtime data only; resource files do not own renderer policy, document state, or file authority.

## Dependencies and boundary

- Keep renderer dependencies vendored and local and load them only through Editor-owned bundle and security policy.
- Preserve deny-by-default CSP and prohibit remote scripts, fonts, fetches, frames, workers, objects, forms, and broader file authority.
- Update upstream version, checksums or integrity evidence, provenance, bundled license text, package metadata, and `THIRD_PARTY_NOTICES.md` together.

## State and invariants

- Use `scripts/vendor-mermaid.sh` for Mermaid updates; treat MathJax replacement as an explicitly reviewed dependency change because no updater script exists.
- Update `scripts/vendor-checksums.sha256` from reviewed upstream files. Vendored content must remain reproducible, local, and covered by its recorded license and integrity evidence.

## Verification

- Run `scripts/check-vendored-resources.sh` after any bundle change.
- Verify resource changes with `LocalWebSecurityTests`, matching renderer tests, and full verification.
