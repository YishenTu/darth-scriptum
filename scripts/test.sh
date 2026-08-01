#!/bin/zsh

set -euo pipefail

usage() {
  print -u2 "Usage: $0 <test-identifier> [...]"
  print -u2 "       $0 --all"
}

if (( $# == 0 )); then
  usage
  exit 2
fi

typeset -a test_selection

if [[ "$1" == "--all" ]]; then
  if (( $# != 1 )); then
    usage
    exit 2
  fi
  test_selection=("-skip-testing:DarthScriptumTests/PerformanceTests")
else
  test_identifier=""
  for test_identifier in "$@"; do
    if [[ "$test_identifier" == -* || "$test_identifier" != DarthScriptumTests/* ]]; then
      print -u2 "Invalid test identifier: $test_identifier"
      usage
      exit 2
    fi
    test_selection+=("-only-testing:$test_identifier")
  done
fi

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
  "${test_selection[@]}" \
  test
