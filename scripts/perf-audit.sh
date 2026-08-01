#!/bin/zsh

set -euo pipefail

script_path="${0:A}"
repository_root="${script_path:h:h}"
verification_config="Sources/Configuration/Verification.xcconfig"

cd "$repository_root"

exec xcodebuild \
  -project DarthScriptum.xcodeproj \
  -scheme DarthScriptum \
  -configuration Benchmark \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  -xcconfig "$verification_config" \
  -onlyUsePackageVersionsFromResolvedFile \
  test \
  -only-testing:DarthScriptumTests/EditPipelinePerformanceAuditTests
