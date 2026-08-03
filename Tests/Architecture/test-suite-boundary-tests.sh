#!/bin/zsh

set -euo pipefail

script_path="${0:A}"
repository_root="${script_path:h:h:h}"
project_file="$repository_root/DarthScriptum.xcodeproj/project.pbxproj"
scheme_root="$repository_root/DarthScriptum.xcodeproj/xcshareddata/xcschemes"
test_script="$repository_root/scripts/test.sh"
verification_script="$repository_root/scripts/verify.sh"
performance_script="$repository_root/scripts/perf-audit.sh"
ci_workflow="$repository_root/.github/workflows/verify.yml"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/darth-scriptum-test-boundaries.XXXXXX")"
build_log="$temporary_root/xcodebuild.log"
build_stub="$temporary_root/xcodebuild"

cleanup() {
    /usr/bin/find "$temporary_root" -depth -delete
}
trap cleanup EXIT

fail() {
    print -u2 -- "$1"
    exit 1
}

assert_file_contains() {
    local file_path="$1"
    local expected="$2"
    /usr/bin/grep -Fq -- "$expected" "$file_path" || \
        fail "Expected $file_path to contain: $expected"
}

assert_file_excludes() {
    local file_path="$1"
    local unexpected="$2"
    if /usr/bin/grep -Fq -- "$unexpected" "$file_path"; then
        fail "Expected $file_path to exclude: $unexpected"
    fi
}

xcodebuild_command_for_selector() {
    local file_path="$1"
    local selector="$2"
    /usr/bin/awk -v selector="$selector" '
        /xcodebuild[[:space:]]*\\[[:space:]]*$/ {
            command = $0
            capturing = 1
            next
        }
        capturing {
            command = command "\n" $0
            if ($0 !~ /\\[[:space:]]*$/) {
                if (index(command, selector) > 0) {
                    print command
                }
                command = ""
                capturing = 0
            }
        }
    ' "$file_path"
}

assert_xcodebuild_route() {
    local file_path="$1"
    local selector="$2"
    local scheme_name="$3"
    local configuration_name="$4"
    local expected_target="$5"
    local command

    command="$(xcodebuild_command_for_selector "$file_path" "$selector")"
    [[ -n "$command" ]] || \
        fail "Missing xcodebuild route for $selector in $file_path."
    if [[ "$command" != *"-scheme $scheme_name"* ]]; then
        [[ "$command" == *'-scheme "$scheme_name"'* ]] || \
            fail "Expected $selector in $file_path to use scheme $scheme_name."
        assert_file_contains "$file_path" "scheme_name=\"$scheme_name\""
    fi
    [[ "$command" == *"-configuration $configuration_name"* ]] || \
        fail "Expected $selector in $file_path to use $configuration_name."

    local other_target
    for other_target in \
        DarthScriptumUnitTests \
        DarthScriptumE2ETests \
        DarthScriptumPerformanceTests
    do
        if [[ "$other_target" != "$expected_target" && "$command" == *"$other_target"* ]]; then
            fail "Expected the $selector route in $file_path to exclude $other_target."
        fi
    done
}

project_target_block() {
    local target_name="$1"
    /usr/bin/awk -v marker="/* $target_name */ = {" '
        index($0, marker) { capturing = 1 }
        capturing { print }
        capturing && /^[[:space:]]*};[[:space:]]*$/ { exit }
    ' "$project_file"
}

assert_suite_mapping() {
    local suite_name="$1"
    local target_name="$2"
    local target_block

    [[ -d "$repository_root/Tests/$suite_name" ]] || \
        fail "Missing Tests/$suite_name suite directory."
    assert_file_contains \
        "$project_file" \
        "/* $suite_name */ = {isa = PBXFileSystemSynchronizedRootGroup; path = Tests/$suite_name;"

    target_block="$(project_target_block "$target_name")"
    [[ -n "$target_block" ]] || fail "Missing $target_name project target."
    [[ "$target_block" == *"fileSystemSynchronizedGroups = ("*"/* $suite_name */"* ]] || \
        fail "Expected $target_name to own the Tests/$suite_name synchronized group."

    local other_suite
    for other_suite in Unit E2E Performance; do
        if [[ "$other_suite" != "$suite_name" && "$target_block" == *"/* $other_suite */"* ]]; then
            fail "Expected $target_name to exclude the Tests/$other_suite synchronized group."
        fi
    done
}

assert_scheme_testable() {
    local scheme_name="$1"
    local target_name="$2"
    local expected_configuration="$3"
    local scheme_path="$scheme_root/$scheme_name.xcscheme"
    local testable_count
    local actual_target
    local actual_configuration

    [[ -f "$scheme_path" ]] || fail "Missing $scheme_name shared scheme."
    testable_count="$(/usr/bin/xmllint --xpath \
        'count(/Scheme/TestAction/Testables/TestableReference)' \
        "$scheme_path")"
    [[ "$testable_count" == 1 ]] || \
        fail "Expected $scheme_name to contain exactly one testable."

    actual_target="$(/usr/bin/xmllint --xpath \
        'string(/Scheme/TestAction/Testables/TestableReference/BuildableReference/@BlueprintName)' \
        "$scheme_path")"
    [[ "$actual_target" == "$target_name" ]] || \
        fail "Expected $scheme_name to test $target_name, found $actual_target."

    actual_configuration="$(/usr/bin/xmllint --xpath \
        'string(/Scheme/TestAction/@buildConfiguration)' \
        "$scheme_path")"
    [[ "$actual_configuration" == "$expected_configuration" ]] || \
        fail "Expected $scheme_name to test with $expected_configuration, found $actual_configuration."
}

assert_suite_mapping Unit DarthScriptumUnitTests
assert_suite_mapping E2E DarthScriptumE2ETests
assert_suite_mapping Performance DarthScriptumPerformanceTests

assert_scheme_testable DarthScriptum DarthScriptumUnitTests Debug
assert_scheme_testable DarthScriptumE2E DarthScriptumE2ETests Debug
assert_scheme_testable DarthScriptumPerformance DarthScriptumPerformanceTests Benchmark

unexpected_swift_tests="$(/usr/bin/find "$repository_root/Tests" \
    -type f \
    -name '*.swift' \
    ! -path "$repository_root/Tests/Unit/*" \
    ! -path "$repository_root/Tests/E2E/*" \
    ! -path "$repository_root/Tests/Performance/*" \
    -print)"
[[ -z "$unexpected_swift_tests" ]] || \
    fail "Swift tests must be under Unit, E2E, or Performance:\n$unexpected_swift_tests"

assert_xcodebuild_route \
    "$verification_script" \
    '-only-testing:DarthScriptumUnitTests' \
    DarthScriptum \
    Debug \
    DarthScriptumUnitTests
assert_xcodebuild_route \
    "$verification_script" \
    '-only-testing:DarthScriptumE2ETests' \
    DarthScriptumE2E \
    Debug \
    DarthScriptumE2ETests
assert_xcodebuild_route \
    "$verification_script" \
    '-only-testing:DarthScriptumPerformanceTests' \
    DarthScriptumPerformance \
    Benchmark \
    DarthScriptumPerformanceTests

assert_xcodebuild_route \
    "$performance_script" \
    '-only-testing:DarthScriptumPerformanceTests/EditPipelinePerformanceAuditTests' \
    DarthScriptumPerformance \
    Benchmark \
    DarthScriptumPerformanceTests

assert_xcodebuild_route \
    "$ci_workflow" \
    '-only-testing:DarthScriptumUnitTests' \
    DarthScriptum \
    Debug \
    DarthScriptumUnitTests
assert_xcodebuild_route \
    "$ci_workflow" \
    '-only-testing:DarthScriptumE2ETests' \
    DarthScriptumE2E \
    Debug \
    DarthScriptumE2ETests
assert_file_excludes "$ci_workflow" 'DarthScriptumPerformance'
assert_file_excludes "$ci_workflow" 'scripts/perf-audit.sh'
assert_file_excludes "$ci_workflow" 'scripts/verify.sh'

{
    print '#!/bin/zsh'
    print 'print -r -- "${(q)@}" >> "$DARTH_SCRIPTUM_XCODEBUILD_LOG"'
} > "$build_stub"
chmod +x "$build_stub"

run_test_script() {
    : > "$build_log"
    DARTH_SCRIPTUM_XCODEBUILD="$build_stub" \
        DARTH_SCRIPTUM_XCODEBUILD_LOG="$build_log" \
        "$test_script" "$@"
}

assert_log_contains() {
    local expected="$1"
    /usr/bin/grep -q -- "$expected" "$build_log" || \
        fail "Expected xcodebuild invocation to contain: $expected"
}

assert_log_excludes() {
    local unexpected="$1"
    if /usr/bin/grep -q -- "$unexpected" "$build_log"; then
        fail "Expected xcodebuild invocation to exclude: $unexpected"
    fi
}

run_test_script --unit
[[ "$(wc -l < "$build_log" | tr -d ' ')" == 1 ]] || \
    fail "Expected --unit to invoke xcodebuild once."
assert_log_contains '-scheme DarthScriptum '
assert_log_contains '-only-testing:DarthScriptumUnitTests'
assert_log_excludes 'DarthScriptumE2ETests'
assert_log_excludes 'DarthScriptumPerformanceTests'

run_test_script --e2e
[[ "$(wc -l < "$build_log" | tr -d ' ')" == 1 ]] || \
    fail "Expected --e2e to invoke xcodebuild once."
assert_log_contains '-scheme DarthScriptumE2E '
assert_log_contains '-only-testing:DarthScriptumE2ETests'
assert_log_excludes 'DarthScriptumUnitTests'
assert_log_excludes 'DarthScriptumPerformanceTests'

run_test_script --all
[[ "$(wc -l < "$build_log" | tr -d ' ')" == 2 ]] || \
    fail "Expected --all to invoke the unit and E2E suites."
assert_log_contains '-only-testing:DarthScriptumUnitTests'
assert_log_contains '-only-testing:DarthScriptumE2ETests'
assert_log_excludes 'DarthScriptumPerformanceTests'

run_test_script DarthScriptumUnitTests/MarkdownSourceBufferTests
assert_log_contains '-only-testing:DarthScriptumUnitTests/MarkdownSourceBufferTests'
assert_log_excludes 'DarthScriptumE2ETests'

run_test_script DarthScriptumE2ETests/CrossBoundaryRegressionTests
[[ "$(wc -l < "$build_log" | tr -d ' ')" == 1 ]] || \
    fail "Expected a focused E2E selection to invoke xcodebuild once."
assert_log_contains '-scheme DarthScriptumE2E '
assert_log_contains '-only-testing:DarthScriptumE2ETests/CrossBoundaryRegressionTests'
assert_log_excludes 'DarthScriptumUnitTests'
assert_log_excludes 'DarthScriptumPerformanceTests'

run_test_script \
    DarthScriptumPerformanceTests/EditPipelinePerformanceAuditTests/testCapturedMutationBindingPipeline
[[ "$(wc -l < "$build_log" | tr -d ' ')" == 1 ]] || \
    fail "Expected a focused performance selection to invoke xcodebuild once."
assert_log_contains '-scheme DarthScriptumPerformance '
assert_log_contains '-configuration Benchmark '
assert_log_contains \
    '-only-testing:DarthScriptumPerformanceTests/EditPipelinePerformanceAuditTests/testCapturedMutationBindingPipeline'
assert_log_excludes 'DarthScriptumUnitTests'
assert_log_excludes 'DarthScriptumE2ETests'

run_test_script \
    DarthScriptumUnitTests/MarkdownSourceBufferTests \
    DarthScriptumE2ETests/CrossBoundaryRegressionTests \
    DarthScriptumPerformanceTests/EditPipelinePerformanceAuditTests/testCapturedMutationBindingPipeline
[[ "$(wc -l < "$build_log" | tr -d ' ')" == 3 ]] || \
    fail "Expected mixed focused selections to invoke each suite once."
assert_log_contains '-only-testing:DarthScriptumUnitTests/MarkdownSourceBufferTests'
assert_log_contains '-only-testing:DarthScriptumE2ETests/CrossBoundaryRegressionTests'
assert_log_contains \
    '-only-testing:DarthScriptumPerformanceTests/EditPipelinePerformanceAuditTests/testCapturedMutationBindingPipeline'

print "Test suite boundary tests passed."
