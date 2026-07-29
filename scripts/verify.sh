#!/bin/zsh

set -euo pipefail

project_path="DarthScriptum.xcodeproj"
scheme_name="DarthScriptum"
destination_name="platform=macOS,arch=arm64"
derived_data="$(mktemp -d "${TMPDIR:-/tmp}/darth-scriptum-verify.XXXXXX")"

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
  -configuration Debug \
  -destination "$destination_name" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  -skip-testing:DarthScriptumTests/PerformanceTests \
  test

xcodebuild \
  -project "$project_path" \
  -scheme "$scheme_name" \
  -configuration Benchmark \
  -destination "$destination_name" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:DarthScriptumTests/PerformanceTests \
  test
