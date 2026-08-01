# DarthScriptum

A lightweight, performance-first Markdown editor for macOS.

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

## Documentation

- [Architecture](docs/architecture.md)
- [Maintenance, dependency updates, and release checks](docs/maintenance.md)

## License

DarthScriptum is available under the [MIT License](LICENSE). Third-party
components retain their respective terms; see
[Third-Party Notices](THIRD_PARTY_NOTICES.md).
