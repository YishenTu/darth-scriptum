# DarthScriptum Development Instructions

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
