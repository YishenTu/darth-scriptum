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
source_root="$repository_root/src"

if [[ ! -d "$source_root" ]]; then
    print -u2 "Architecture check expected src directory: $source_root"
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

core_directory="$source_root/core"
document_directory="$source_root/document"
editor_directory="$source_root/editor"

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

swift_import_prefix='^[[:space:]]*(@[^[:space:]]+[[:space:]]+)*import[[:space:]]+((class|enum|func|let|protocol|struct|var)[[:space:]]+)?'
forbidden_ui_or_engine_import="${swift_import_prefix}(AppKit|SwiftUI|WebKit|MarkdownEngine|MarkdownEngineLatex|MarkdownEngineCodeBlocks)([[:space:].]|$)"
forbidden_document_engine_import="${swift_import_prefix}(SwiftUI|WebKit|MarkdownEngine|MarkdownEngineLatex|MarkdownEngineCodeBlocks)([[:space:].]|$)"
appkit_import="${swift_import_prefix}AppKit([[:space:].]|$)"
upper_layer_reference='\b(MarkdownDocument|MarkdownWindowController|WorkspaceModel|MarkdownWorkspace|LivePreviewTextView|EditorPaneStateCoordinator)\b'
editor_persistence_reference='\b(DocumentSyncCoordinator|DocumentSyncCoordinatorDelegate|SessionRecoveryStore|SafeFileCommitter|CommitRecoveryJournalStore|SaveTransactionBridge|DirectoryFileMonitor|TextFileCodec|ThreeWayTextMerger|DurableFileIO|PendingSaveToken|DurableFileState|FileFingerprint)\b'
internal_markdown_engine_key='\b(LatexRenderedImage|LatexImageBounds|LatexIsBlock|LatexBlockOffsetY|ThematicBreak|BlockquoteLevel|BulletListMarker|ScrollableBlockNaturalWidth|ScrollableBlockSourceID|ScrollableBlockTotalHeight|ScrollableBlockFullRange|NodeLinkID|TaskCheckbox)\b'

assert_legacy_ownership_paths_absent \
    "$document_directory/markdownsourcebuffer.swift" \
    "$document_directory/markdowndocument.swift"

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
    "$editor_directory/markdownenginecompatibility.swift" \
    "$editor_directory/markdownenginecompatibility.swiftfixture" || true)"
if [[ -n "$markdown_engine_compatibility_file" ]]; then
    scan_pattern \
        "$source_root" \
        "$internal_markdown_engine_key" \
        "raw MarkdownEngine internal attribute keys belong only in markdownenginecompatibility.swift" \
        "$markdown_engine_compatibility_file"
fi

if (( violation_count > 0 )); then
    print -u2 "Architecture check failed with $violation_count violation(s)."
    exit 1
fi

print "Architecture check passed."
if [[ -z "$markdown_engine_compatibility_file" ]]; then
    print "Migration target: raw MarkdownEngine internal-key location enforcement activates when E1 adds src/editor/markdownenginecompatibility.swift."
fi
