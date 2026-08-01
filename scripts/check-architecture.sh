#!/bin/zsh

set -euo pipefail

usage() {
    print -u2 "Usage: $0 [--repo-root <path>]"
}

script_path="${0:A}"
default_repository_root="${script_path:h:h}"
repository_root="$default_repository_root"

case "$#" in
    0)
        ;;
    2)
        if [[ "$1" != "--repo-root" ]]; then
            usage
            exit 2
        fi
        repository_root="$2"
        ;;
    *)
        usage
        exit 2
        ;;
esac

if [[ ! -d "$repository_root" ]]; then
    print -u2 "Architecture check repository root does not exist: $repository_root"
    exit 2
fi
repository_root="$(cd "$repository_root" && pwd -P)"
source_root="$repository_root/Sources"
tests_root="$repository_root/Tests"

if [[ ! -d "$source_root" ]]; then
    print -u2 "Architecture check expected Sources directory: $source_root"
    exit 2
fi
if ! command -v rg >/dev/null 2>&1; then
    print -u2 "Architecture check requires ripgrep (rg)."
    exit 2
fi

integer violation_count=0

relative_path() {
    local path="$1"
    print -r -- "${path#$repository_root/}"
}

report_violation() {
    local message="$1"
    print -u2 "architecture violation: $message"
    (( violation_count += 1 ))
}

validate_scoped_instructions() {
    local scoped_directory
    local agents_file
    local claude_file
    local relative_agents_file
    local relative_claude_file
    local discovered_file
    local relative_discovered_file
    local -a scoped_directories=(
        "$source_root/App"
        "$source_root/Core"
        "$source_root/Document"
        "$source_root/Editor"
        "$source_root/Workspace"
        "$source_root/Resources"
        "$tests_root"
    )
    local -A expected_files

    for scoped_directory in "${scoped_directories[@]}"; do
        agents_file="$scoped_directory/AGENTS.md"
        claude_file="$scoped_directory/CLAUDE.md"
        relative_agents_file="$(relative_path "$agents_file")"
        relative_claude_file="$(relative_path "$claude_file")"
        expected_files[$relative_agents_file]=1
        expected_files[$relative_claude_file]=1

        if [[ ! -f "$agents_file" ]]; then
            report_violation "required scoped AGENTS.md is missing: $relative_agents_file"
        elif [[ ! -s "$agents_file" ]]; then
            report_violation "scoped AGENTS.md must not be empty: $relative_agents_file"
        fi

        if [[ ! -f "$claude_file" ]]; then
            report_violation "required scoped CLAUDE.md is missing: $relative_claude_file"
        elif ! /usr/bin/cmp -s "$claude_file" <(/usr/bin/printf '@AGENTS.md\n'); then
            report_violation "scoped CLAUDE.md must contain exactly @AGENTS.md plus a terminal newline: $relative_claude_file"
        fi
    done

    while IFS= read -r -d '' discovered_file; do
        relative_discovered_file="$(relative_path "$discovered_file")"
        if [[ -z "${expected_files[$relative_discovered_file]-}" ]]; then
            report_violation "unexpected scoped instruction file: $relative_discovered_file"
        fi
    done < <(
        /usr/bin/find "$source_root" "$tests_root" \
            \( -name AGENTS.md -o -name CLAUDE.md \) \
            -print0
    )
}

scan_pattern() {
    local directory="$1"
    local pattern="$2"
    local rule="$3"
    local exempt_file="${4:-}"
    local files
    local file
    local scan_status

    [[ -d "$directory" ]] || return 0

    if files="$(command rg --files "$directory" -g '*.swift' -g '*.swiftfixture')"; then
        :
    else
        scan_status=$?
        if (( scan_status == 1 )); then
            return 0
        fi
        print -u2 "Architecture check could not list source files: $directory"
        exit 2
    fi

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        [[ -n "$exempt_file" && "$file" == "$exempt_file" ]] && continue
        if command rg -q -- "$pattern" "$file"; then
            report_violation "$rule: $(relative_path "$file")"
        else
            scan_status=$?
            if (( scan_status > 1 )); then
                print -u2 "Architecture check could not scan source file: $file"
                exit 2
            fi
        fi
    done <<< "$files"
}

first_existing_file() {
    local candidate
    for candidate in "$@"; do
        if [[ -f "$candidate" ]]; then
            print -r -- "$candidate"
            return 0
        fi
    done
    return 1
}

core_directory="$source_root/Core"
document_directory="$source_root/Document"
editor_directory="$source_root/Editor"

assert_legacy_ownership_paths_absent() {
    local legacy_path
    local candidate

    for legacy_path in "$@"; do
        for candidate in "$legacy_path" "${legacy_path}fixture"; do
            [[ -e "$candidate" || -L "$candidate" ]] || continue
            report_violation "legacy ownership path must not exist: $(relative_path "$candidate")"
        done
    done
}

if [[ -f "$repository_root/DarthScriptum.xcodeproj/project.pbxproj" ]]; then
    if [[ ! -d "$tests_root" ]]; then
        print -u2 "Architecture check expected Tests directory: $tests_root"
        exit 2
    fi
    validate_scoped_instructions
fi

swift_import_prefix='^[[:space:]]*(@[^[:space:]]+[[:space:]]+)*import[[:space:]]+((class|enum|func|let|protocol|struct|var)[[:space:]]+)?'
forbidden_ui_or_engine_import="${swift_import_prefix}(AppKit|SwiftUI|WebKit|MarkdownEngine|MarkdownEngineLatex|MarkdownEngineCodeBlocks)([[:space:].]|$)"
forbidden_document_engine_import="${swift_import_prefix}(SwiftUI|WebKit|MarkdownEngine|MarkdownEngineLatex|MarkdownEngineCodeBlocks)([[:space:].]|$)"
appkit_import="${swift_import_prefix}AppKit([[:space:].]|$)"
upper_layer_reference='\b(MarkdownDocument|MarkdownWindowController|WorkspaceModel|MarkdownWorkspace|LivePreviewTextView|EditorPaneStateCoordinator)\b'
editor_persistence_reference='\b(DocumentSyncCoordinator|DocumentSyncCoordinatorDelegate|SessionRecoveryStore|SafeFileCommitter|CommitRecoveryJournalStore|SaveTransactionBridge|DirectoryFileMonitor|TextFileCodec|ThreeWayTextMerger|DurableFileIO|PendingSaveToken|DurableFileState|FileFingerprint)\b'
internal_markdown_engine_key='\b(LatexRenderedImage|LatexImageBounds|LatexIsBlock|LatexBlockOffsetY|ThematicBreak|BlockquoteLevel|BulletListMarker|ScrollableBlockNaturalWidth|ScrollableBlockSourceID|ScrollableBlockTotalHeight|ScrollableBlockFullRange|NodeLinkID|TaskCheckbox)\b'

assert_legacy_ownership_paths_absent \
    "$document_directory/MarkdownSourceBuffer.swift" \
    "$document_directory/MarkdownDocument.swift" \
    "$document_directory/markdown-source-buffer.swift" \
    "$document_directory/markdown-document.swift"

scan_pattern \
    "$core_directory" \
    "$forbidden_ui_or_engine_import" \
    "core must not import UI, WebKit, or MarkdownEngine frameworks"
scan_pattern \
    "$document_directory" \
    "$forbidden_document_engine_import" \
    "document must not import SwiftUI, WebKit, or MarkdownEngine frameworks"
scan_pattern \
    "$document_directory" \
    "$appkit_import" \
    "document must not import AppKit"

scan_pattern \
    "$core_directory" \
    "$upper_layer_reference" \
    "core must not reference app, workspace, or editor host types"
scan_pattern \
    "$document_directory" \
    "$upper_layer_reference" \
    "document must not reference app, workspace, or editor host types"
scan_pattern \
    "$editor_directory" \
    "$editor_persistence_reference" \
    "editor must not reference concrete synchronization or persistence types"

markdown_engine_compatibility_file="$(first_existing_file \
    "$editor_directory/Compatibility/MarkdownEngineCompatibility.swift" \
    "$editor_directory/Compatibility/markdown-engine-compatibility.swiftfixture" || true)"
if [[ -n "$markdown_engine_compatibility_file" ]]; then
    scan_pattern \
        "$source_root" \
        "$internal_markdown_engine_key" \
        "raw MarkdownEngine internal attribute keys belong only in MarkdownEngineCompatibility.swift" \
        "$markdown_engine_compatibility_file"
fi

if (( violation_count > 0 )); then
    print -u2 "Architecture check failed with $violation_count violation(s)."
    exit 1
fi

print "Architecture check passed."
