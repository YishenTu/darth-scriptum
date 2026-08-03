#!/bin/zsh

set -euo pipefail

usage() {
  print -u2 "Usage: $0 --unit"
  print -u2 "       $0 --e2e"
  print -u2 "       $0 --all"
  print -u2 "       $0 <test-identifier> [...]"
}

if (( $# == 0 )); then
  usage
  exit 2
fi

script_path="${0:A}"
repository_root="${script_path:h:h}"
verification_config="Sources/Configuration/Verification.xcconfig"
xcodebuild_command="${DARTH_SCRIPTUM_XCODEBUILD:-xcodebuild}"

cd "$repository_root"

run_suite() {
  local scheme_name="$1"
  local configuration_name="$2"
  shift 2

  "$xcodebuild_command" \
    -project DarthScriptum.xcodeproj \
    -scheme "$scheme_name" \
    -configuration "$configuration_name" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath DerivedData \
    -xcconfig "$verification_config" \
    -onlyUsePackageVersionsFromResolvedFile \
    "$@" \
    test
}

if [[ "$1" == --unit || "$1" == --e2e || "$1" == --all ]]; then
  if (( $# != 1 )); then
    usage
    exit 2
  fi

  case "$1" in
    --unit)
      run_suite DarthScriptum Debug \
        -only-testing:DarthScriptumUnitTests
      ;;
    --e2e)
      run_suite DarthScriptumE2E Debug \
        -only-testing:DarthScriptumE2ETests
      ;;
    --all)
      run_suite DarthScriptum Debug \
        -only-testing:DarthScriptumUnitTests
      run_suite DarthScriptumE2E Debug \
        -only-testing:DarthScriptumE2ETests
      ;;
  esac
  exit
fi

typeset -a unit_selection e2e_selection performance_selection
test_identifier=""
for test_identifier in "$@"; do
  case "$test_identifier" in
    DarthScriptumUnitTests/*)
      unit_selection+=("-only-testing:$test_identifier")
      ;;
    DarthScriptumE2ETests/*)
      e2e_selection+=("-only-testing:$test_identifier")
      ;;
    DarthScriptumPerformanceTests/*)
      performance_selection+=("-only-testing:$test_identifier")
      ;;
    *)
      print -u2 "Invalid test identifier: $test_identifier"
      usage
      exit 2
      ;;
  esac
done

if (( ${#unit_selection} > 0 )); then
  run_suite DarthScriptum Debug "${unit_selection[@]}"
fi
if (( ${#e2e_selection} > 0 )); then
  run_suite DarthScriptumE2E Debug "${e2e_selection[@]}"
fi
if (( ${#performance_selection} > 0 )); then
  run_suite DarthScriptumPerformance Benchmark "${performance_selection[@]}"
fi
