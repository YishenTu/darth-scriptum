#!/bin/zsh

set -euo pipefail

script_path="${0:A}"
repository_root="${script_path:h:h}"
project_path="DarthScriptum.xcodeproj"
scheme_name="DarthScriptum"
destination_name="platform=macOS,arch=arm64"
verification_config="Sources/Configuration/Verification.xcconfig"
derived_data="$(mktemp -d "${TMPDIR:-/tmp}/darth-scriptum-verify.XXXXXX")"

cleanup() {
  /usr/bin/find "$derived_data" -depth -delete
}
trap cleanup EXIT

cd "$repository_root"

./scripts/lint.sh
./scripts/check-vendored-resources.sh
./scripts/check-architecture.sh
Tests/Architecture/run-tests.sh

xcodebuild \
  -project "$project_path" \
  -scheme "$scheme_name" \
  -configuration Debug \
  -destination "$destination_name" \
  -derivedDataPath "$derived_data" \
  -xcconfig "$verification_config" \
  -onlyUsePackageVersionsFromResolvedFile \
  build

xcodebuild \
  -project "$project_path" \
  -scheme "$scheme_name" \
  -configuration Release \
  -destination "$destination_name" \
  -derivedDataPath "$derived_data" \
  -xcconfig "$verification_config" \
  -onlyUsePackageVersionsFromResolvedFile \
  build

xcodebuild \
  -project "$project_path" \
  -scheme "$scheme_name" \
  -configuration Debug \
  -destination "$destination_name" \
  -derivedDataPath "$derived_data" \
  -xcconfig "$verification_config" \
  -onlyUsePackageVersionsFromResolvedFile \
  -skip-testing:DarthScriptumTests/PerformanceTests \
  -skip-testing:DarthScriptumTests/EditPipelinePerformanceAuditTests \
  test

xcodebuild \
  -project "$project_path" \
  -scheme "$scheme_name" \
  -configuration Benchmark \
  -destination "$destination_name" \
  -derivedDataPath "$derived_data" \
  -xcconfig "$verification_config" \
  -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:DarthScriptumTests/PerformanceTests \
  -only-testing:DarthScriptumTests/EditPipelinePerformanceAuditTests \
  test
