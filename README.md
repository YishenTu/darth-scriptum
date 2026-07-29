# DarthScriptum

A lightweight, performance-first Markdown editor and viewer for macOS.

DarthScriptum is built for opening a file, writing, and getting out of the way. It uses a native TextKit 2 editor instead of a browser-based editing surface and keeps the Markdown source as the document.

## Highlights

- Native live preview and source editing in one surface
- Fast, incremental rendering with a plain-source fallback for large files
- Automatic saving and live updates when another app changes the file
- Safe merging and recovery for conflicting edits
- Native tabs and an optional same-document split view
- Local rendering for images, TeX math, Mermaid diagrams, and common Markdown syntax
- No vault, account, database, sidebar, or remote content loading

## Requirements

- macOS 14 or later
- Xcode with Swift 6 support

## Build

```sh
xcodebuild \
  -project DarthScriptum.xcodeproj \
  -scheme DarthScriptum \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The app will be available at:

```text
DerivedData/Build/Products/Debug/DarthScriptum.app
```

## Verify

Run the complete test and build suite:

```sh
./scripts/verify.sh
```
