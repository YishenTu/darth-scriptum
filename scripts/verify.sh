#!/bin/zsh

set -euo pipefail

script_path="${0:A}"
repository_root="${script_path:h:h}"
project_path="DarthScriptum.xcodeproj"
scheme_name="DarthScriptum"
destination_name="platform=macOS,arch=arm64"
derived_data="$(mktemp -d "${TMPDIR:-/tmp}/darth-scriptum-verify.XXXXXX")"

cleanup() {
  /usr/bin/find "$derived_data" -depth -delete
}
trap cleanup EXIT

cd "$repository_root"

./scripts/check-architecture.sh
tests/architecture/run-tests.sh

xcodebuild \
  -project "$project_path" \
  -scheme "$scheme_name" \
  -configuration Debug \
  -destination "$destination_name" \
  -derivedDataPath "$derived_data" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  build

xcodebuild \
  -project "$project_path" \
  -scheme "$scheme_name" \
  -configuration Release \
  -destination "$destination_name" \
  -derivedDataPath "$derived_data" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  build

xcodebuild \
  -project "$project_path" \
  -scheme "$scheme_name" \
  -configuration Debug \
  -destination "$destination_name" \
  -derivedDataPath "$derived_data" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  -skip-testing:DarthScriptumTests/PerformanceTests \
  test

xcodebuild \
  -project "$project_path" \
  -scheme "$scheme_name" \
  -configuration Benchmark \
  -destination "$destination_name" \
  -derivedDataPath "$derived_data" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  -only-testing:DarthScriptumTests/PerformanceTests \
  test
