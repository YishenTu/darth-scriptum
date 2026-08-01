#!/bin/zsh

set -euo pipefail

script_path="${0:A}"
repository_root="${script_path:h:h}"
verification_config="Sources/Configuration/Verification.xcconfig"

cd "$repository_root"

xcodebuild \
  -project DarthScriptum.xcodeproj \
  -scheme DarthScriptum \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  -xcconfig "$verification_config" \
  -onlyUsePackageVersionsFromResolvedFile \
  build
