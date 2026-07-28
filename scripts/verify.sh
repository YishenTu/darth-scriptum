#!/bin/zsh

set -euo pipefail

project_path="darth-md.xcodeproj"
scheme_name="darth-md"
destination_name="platform=macOS,arch=arm64"
derived_data="$(mktemp -d "${TMPDIR:-/tmp}/darth-md-verify.XXXXXX")"

cleanup() {
  /usr/bin/find "$derived_data" -depth -delete
}
trap cleanup EXIT

xcodebuild \
  -project "$project_path" \
  -scheme "$scheme_name" \
  -configuration Debug \
  -destination "$destination_name" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project "$project_path" \
  -scheme "$scheme_name" \
  -configuration Release \
  -destination "$destination_name" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project "$project_path" \
  -scheme "$scheme_name" \
  -destination "$destination_name" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  test
