#!/bin/zsh

set -euo pipefail

script_path="${0:A}"
script_root="${script_path:h}"
repository_root="${script_root:h:h}"
check_script="$repository_root/scripts/check-architecture.sh"
fixtures_root="$script_root/Fixtures"

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
assert_rejects planned-ownership-exceptions Sources/Document/markdown-source-buffer.swiftfixture
assert_rejects planned-ownership-exceptions Sources/Document/markdown-document.swiftfixture
assert_rejects core-forbidden-framework Sources/Core/core-framework-violation.swiftfixture
assert_rejects document-forbidden-framework Sources/Document/document-framework-violation.swiftfixture
assert_rejects core-forbidden-upper-layer Sources/Core/core-upper-layer-violation.swiftfixture
assert_rejects document-forbidden-upper-layer Sources/Document/document-upper-layer-violation.swiftfixture
assert_rejects editor-forbidden-persistence Sources/Editor/editor-persistence-violation.swiftfixture
assert_rejects workspace-forbidden-persistence Sources/Workspace/workspace-persistence-violation.swiftfixture
assert_rejects workspace-forbidden-app Sources/Workspace/workspace-app-violation.swiftfixture
assert_rejects design-system-forbidden-feature Sources/DesignSystem/design-system-feature-violation.swiftfixture
assert_rejects design-system-forbidden-framework Sources/DesignSystem/design-system-framework-violation.swiftfixture
assert_rejects internal-key-outside-compatibility Sources/Editor/editor-internal-key-violation.swiftfixture
assert_rejects internal-key-outside-compatibility Sources/Workspace/workspace-internal-key-violation.swiftfixture

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

assert_requires_design_system_scoped_instructions() {
    local temporary_root
    local output
    local scoped_directory
    local -a scoped_directories=(
        Sources/App
        Sources/Core
        Sources/DesignSystem
        Sources/Document
        Sources/Editor
        Sources/Resources
        Sources/Workspace
        Tests
    )

    temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/darth-scriptum-scoped-instructions.XXXXXX")"
    mkdir -p "$temporary_root/DarthScriptum.xcodeproj"
    print '// Fixture marker.' > "$temporary_root/DarthScriptum.xcodeproj/project.pbxproj"
    for scoped_directory in "${scoped_directories[@]}"; do
        mkdir -p "$temporary_root/$scoped_directory"
        print '# Boundary' > "$temporary_root/$scoped_directory/AGENTS.md"
        print '@AGENTS.md' > "$temporary_root/$scoped_directory/CLAUDE.md"
    done

    if ! output="$("$check_script" --repo-root "$temporary_root" 2>&1)"; then
        print -u2 "Expected complete scoped instructions to pass, but they failed:"
        print -u2 -- "$output"
        /usr/bin/find "$temporary_root" -depth -delete
        exit 1
    fi

    /usr/bin/find "$temporary_root/Sources/DesignSystem" -depth -delete
    if output="$("$check_script" --repo-root "$temporary_root" 2>&1)"; then
        print -u2 "Expected missing DesignSystem instructions to fail, but they passed:"
        print -u2 -- "$output"
        /usr/bin/find "$temporary_root" -depth -delete
        exit 1
    fi
    if [[ "$output" != *"required scoped AGENTS.md is missing: Sources/DesignSystem/AGENTS.md"* ]]; then
        print -u2 "Expected the failure to name the missing DesignSystem instructions:"
        print -u2 -- "$output"
        /usr/bin/find "$temporary_root" -depth -delete
        exit 1
    fi
    /usr/bin/find "$temporary_root" -depth -delete
}

assert_requires_design_system_scoped_instructions

"$script_root/test-suite-boundary-tests.sh"

print "Architecture fixture tests passed."
