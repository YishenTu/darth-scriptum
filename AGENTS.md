# DarthMD Development Instructions

## Build and verification

- Preserve the native macOS architecture and keep changes focused on the requested behavior.
- After changing code, run the relevant tests and build the Debug app before handing the work back.
- Use a repository-local Derived Data directory so the runnable app has a predictable path:

```sh
xcodebuild \
  -project darth-md.xcodeproj \
  -scheme darth-md \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

- Run `./scripts/verify.sh` for changes with broad impact or before committing a completed implementation.

## Relaunch after code changes

- After a successful build of any runtime-affecting change, gracefully quit the currently running DarthMD process, launch `DerivedData/Build/Products/Debug/DarthMD.app`, and confirm that its window is visible.
- Leave the relaunched Debug app running so the user can test the result.
- Do not relaunch for documentation-only, test-only, or other non-runtime changes.
- Do not copy the app into `/Applications` during normal development. Installing is only necessary when the user explicitly asks for it or when testing packaging, signing, updates, or distribution behavior.

## Fast local feedback

- For interactive development in Xcode, use **Run** (`Command-R`). Xcode builds the changed sources, stops the previous debug process, and launches the new build automatically.
- For command-line or agent-driven work, build into the repository-local `DerivedData/` path above and relaunch that exact app bundle.
