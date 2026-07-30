# DarthScriptum Development Instructions

## Project structure

- Organize code by clear domain responsibility rather than accumulating related files in flat directories.
- Keep each feature's public entry point small and obvious; place its contracts, state, orchestration, adapters, persistence, and implementation in focused subfolders when the feature warrants them.
- Use meaningful ownership-based folder names. Do not create catch-all `utils`, `common`, or miscellaneous folders.
- Mirror the relevant production structure in tests so ownership and coverage remain easy to find.
- Avoid both flat dumping grounds and unnecessary nesting. Before a material reorganization, propose the target tree and explain each group's responsibility.
- Preserve project tooling, build configuration, imports, and test discovery when moving files, and verify the affected build and tests afterward.

## Build and verification

- Preserve the native macOS architecture and keep changes focused on the requested behavior.
- After changing code, run the relevant tests and build the Debug app before handing the work back.
- Use a repository-local Derived Data directory so the runnable app has a predictable path:

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

- Run `./scripts/verify.sh` for changes with broad impact or before committing a completed implementation.

## Fast local feedback

- For interactive development in Xcode, use **Build** (`Command-B`) unless UI validation is explicitly requested.
- For command-line or agent-driven work, build into the repository-local `DerivedData/` path above.
- Launch or install the app only when the user explicitly requests UI, packaging, signing, update, or distribution validation.
