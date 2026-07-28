# DarthMD

DarthMD is a focused, native macOS Markdown editor: the speed and document workflow of TextEdit, with an Obsidian-style Live Preview surface. It has no vault, sidebar, database, account, web renderer, or file-management layer.

## Requirements

- macOS 14 or later
- Xcode 26.4 or later
- Swift 6

## What it does

- Edits and renders exact Markdown in one TextKit 2 surface. Live Preview changes presentation only; copied and saved text stays Markdown.
- Writes existing files through after 100 ms of typing inactivity. There is no Save action: the editor continuously reflects and updates the file.
- Watches both the file and its parent directory, so direct writes and atomic replacements made by tools such as Codex refresh in place.
- Merges simultaneous non-overlapping line edits. For an overlap, the current disk revision is shown and the displaced local revision is recoverable from `View > Restore Local Revision`.
- Journals the final atomic exchange before it happens. If DarthMD or macOS stops during a contested save, the displaced external bytes remain durable and are imported into recovery on the next launch.
- Uses native macOS tabs and an optional two-pane view of the same document. Each pane keeps its own selection and scroll position.
- Preserves UTF-8, UTF-8 BOM, BOM-marked UTF-16, and the file's existing line-ending style.
- Supports headings, emphasis, strikethrough, inline and fenced code, links, lists, task items, quotes, thematic breaks, and styled tables. Relative local images render inline; remote images and raw HTML remain inert source.
- Never executes raw HTML or downloads remote images.
- Live Preview uses the engine's synchronous incremental parser, so asynchronous parse jobs cannot accumulate while typing.
- Files above 2 MiB stay fully editable and automatically use a plain-source presentation fallback instead of blocking on a full Markdown parse.

The first release is an unsandboxed direct-download desktop application. That is intentional: arbitrary files, parent-directory monitoring, and relative local resources are part of the document model.

On filesystems that do not support atomic rename exchange, DarthMD refuses an unsafe in-place replacement instead of risking another process's edit. Use Save As to write a new file on that volume.

## Build and test

```sh
xcodebuild -project darth-md.xcodeproj -scheme darth-md -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project darth-md.xcodeproj -scheme darth-md -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

## Shortcuts

- `Command-Shift-M`: toggle Live Preview/source mode
- `Command-Shift-X`: toggle a task marker
- `Command-\`: toggle the same-document split
- `Command-Option-]`: focus the next pane
- `Command-Plus`, `Command-Minus`, `Command-0`: editor zoom

## Structure

- `src/`: application, document synchronization, editor, presentation, theme, and workspace code
- `tests/`: unit, integration, race-regression, and performance tests
- `ui-tests/`: application launch and native UI checks
- `scripts/`: reproducible verification entry point
- `.context/`: ignored planning, handoff, and validation evidence

## Verification

Run clean Debug and Release builds plus the complete test suite:

```sh
./scripts/verify.sh
```
