#!/bin/sh
set -eu

version="11.16.0"
archive_sha256="ff48c94a0a0458b377a5187ad01407184d2a182e6476c2015b7068ff58355fae"
bundle_sha256="74d7c46dabca328c2294733910a8aa1ed0c37451776e8d5295da38a2b758fb9b"
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination="$repository_root/src/resources/Mermaid.bundle"
vendor_tmp=$(mktemp -d)
trap 'rm -rf "$vendor_tmp"' EXIT HUP INT TERM

archive="$vendor_tmp/mermaid.tgz"
curl --fail --location --silent --show-error \
  "https://registry.npmjs.org/mermaid/-/mermaid-${version}.tgz" \
  --output "$archive"

actual_archive_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
if [ "$actual_archive_sha256" != "$archive_sha256" ]; then
  echo "Mermaid archive checksum mismatch." >&2
  exit 1
fi

tar -xzf "$archive" -C "$vendor_tmp" \
  package/dist/mermaid.min.js \
  package/LICENSE \
  package/package.json

actual_bundle_sha256=$(
  shasum -a 256 "$vendor_tmp/package/dist/mermaid.min.js" | awk '{print $1}'
)
if [ "$actual_bundle_sha256" != "$bundle_sha256" ]; then
  echo "Mermaid bundle checksum mismatch." >&2
  exit 1
fi

mkdir -p "$destination"
cp "$vendor_tmp/package/dist/mermaid.min.js" "$destination/mermaid.min.js"
cp "$vendor_tmp/package/LICENSE" "$destination/LICENSE"
cp "$vendor_tmp/package/package.json" "$destination/package.json"

echo "Vendored Mermaid ${version}."
