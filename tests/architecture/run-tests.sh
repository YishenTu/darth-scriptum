#!/bin/zsh

set -euo pipefail

script_path="${0:A}"
script_root="${script_path:h}"
repository_root="${script_root:h:h}"
check_script="$repository_root/scripts/check-architecture.sh"
fixtures_root="$script_root/fixtures"

if [[ ! -x "$check_script" ]]; then
    print -u2 "Missing executable architecture check: $check_script"
    exit 1
fi

assert_accepts() {
    local fixture_name="$1"
    local output

    if ! output="$("$check_script" --repo-root "$fixtures_root/$fixture_name" 2>&1)"; then
        print -u2 "Expected $fixture_name to pass, but it failed:"
        print -u2 -- "$output"
        exit 1
    fi
}

assert_rejects() {
    local fixture_name="$1"
    local expected_path="$2"
    local output

    if output="$("$check_script" --repo-root "$fixtures_root/$fixture_name" 2>&1)"; then
        print -u2 "Expected $fixture_name to fail, but it passed:"
        print -u2 -- "$output"
        exit 1
    fi
    if [[ "$output" != *"$expected_path"* ]]; then
        print -u2 "Expected $fixture_name failure to name $expected_path:"
        print -u2 -- "$output"
        exit 1
    fi
}

assert_accepts permitted-current-imports
assert_accepts planned-ownership-exceptions
assert_rejects core-forbidden-framework src/core/core-framework-violation.swiftfixture
assert_rejects document-forbidden-framework src/document/document-framework-violation.swiftfixture
assert_rejects core-forbidden-upper-layer src/core/core-upper-layer-violation.swiftfixture
assert_rejects document-forbidden-upper-layer src/document/document-upper-layer-violation.swiftfixture
assert_rejects editor-forbidden-persistence src/editor/editor-persistence-violation.swiftfixture
assert_rejects internal-key-outside-compatibility src/editor/editor-internal-key-violation.swiftfixture
assert_rejects internal-key-outside-compatibility src/workspace/workspace-internal-key-violation.swiftfixture

assert_requires_ripgrep() {
    local output

    if output="$(PATH="" "$check_script" --repo-root "$fixtures_root/permitted-current-imports" 2>&1)"; then
        print -u2 "Expected the architecture check to fail without ripgrep, but it passed:"
        print -u2 -- "$output"
        exit 1
    fi
    if [[ "$output" != *"requires ripgrep (rg)"* ]]; then
        print -u2 "Expected the missing-ripgrep failure to explain the dependency:"
        print -u2 -- "$output"
        exit 1
    fi
}

assert_requires_ripgrep

print "Architecture fixture tests passed."
