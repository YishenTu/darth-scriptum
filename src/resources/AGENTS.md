# Resource boundary

- Keep renderer dependencies vendored and local; see [the architecture](../../docs/architecture.md) and [the update procedure](../../docs/maintenance.md#vendored-renderer-updates).
- Preserve deny-by-default CSP and prohibit remote scripts, fonts, fetches, frames, workers, objects, forms, and broader file authority.
- Update upstream version, checksums or integrity evidence, provenance, bundled license text, package metadata, and `THIRD_PARTY_NOTICES.md` together.
- Use `scripts/vendor-mermaid.sh` for Mermaid updates; treat MathJax replacement as an explicitly reviewed dependency change because no updater script exists.
- Verify resource changes with `LocalWebSecurityTests`, the matching renderer tests, and full verification.
