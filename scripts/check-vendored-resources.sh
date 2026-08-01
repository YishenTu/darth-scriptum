#!/bin/zsh

set -euo pipefail

script_path="${0:A}"
repository_root="${script_path:h:h}"
checksum_manifest="scripts/vendor-checksums.sha256"

cd "$repository_root"

typeset -a bundle_roots=(
  Sources/Resources/MathJax.bundle
  Sources/Resources/Mermaid.bundle
)
typeset -a expected_files=(
  Sources/Resources/MathJax.bundle/LICENSE
  Sources/Resources/MathJax.bundle/mathjax-config.js
  Sources/Resources/MathJax.bundle/mathjax-renderer.html
  Sources/Resources/MathJax.bundle/mathjax-renderer.js
  Sources/Resources/MathJax.bundle/package.json
  Sources/Resources/MathJax.bundle/tex-svg-full.js
  Sources/Resources/Mermaid.bundle/LICENSE
  Sources/Resources/Mermaid.bundle/mermaid-renderer.html
  Sources/Resources/Mermaid.bundle/mermaid-renderer.js
  Sources/Resources/Mermaid.bundle/mermaid.min.js
  Sources/Resources/Mermaid.bundle/package.json
)

if [[ -n "$(find "${bundle_roots[@]}" -type l -print -quit)" ]]; then
  print -u2 "Vendored resource bundles must not contain symbolic links."
  exit 1
fi

actual_files="$(
  find "${bundle_roots[@]}" -type f -print | LC_ALL=C sort
)"
expected_file_list="$(printf '%s\n' "${expected_files[@]}" | LC_ALL=C sort)"
if [[ "$actual_files" != "$expected_file_list" ]]; then
  print -u2 "Vendored resource bundle contents do not match the allowlist."
  diff -u \
    <(printf '%s\n' "$expected_file_list") \
    <(printf '%s\n' "$actual_files") || true
  exit 1
fi

shasum -a 256 --check "$checksum_manifest"

rg -q '"version"[[:space:]]*:[[:space:]]*"3\.2\.2"' \
  Sources/Resources/MathJax.bundle/package.json
rg -q '"version"[[:space:]]*:[[:space:]]*"11\.16\.0"' \
  Sources/Resources/Mermaid.bundle/package.json

print "Vendored resource check passed."
