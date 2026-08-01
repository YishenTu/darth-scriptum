# DarthScriptum

A lightweight, performance-first Markdown editor for macOS.

## Requirements

- macOS 14 or later
- Xcode with Swift 6 support

## Build

```sh
./scripts/build-debug.sh
```

The app will be available at:

```text
DerivedData/Build/Products/Debug/DarthScriptum.app
```

## Lint

```sh
./scripts/lint.sh
```

## Test

Run one or more focused test identifiers:

```sh
./scripts/test.sh DarthScriptumTests/SourceTypesTests
```

Run the complete non-performance test suite:

```sh
./scripts/test.sh --all
```

## Full verification

Run the complete test and build suite:

```sh
./scripts/verify.sh
```

Verify vendored renderer files without building:

```sh
./scripts/check-vendored-resources.sh
```

## Performance audit

Run the focused edit-pipeline benchmark with:

```sh
./scripts/perf-audit.sh
```

The recorded baseline, performance budgets, and comparison method are in the
[performance audit](docs/performance-audit.md).

## License

DarthScriptum is available under the [MIT License](LICENSE). Third-party
components retain their respective terms; see
[Third-Party Notices](THIRD_PARTY_NOTICES.md).
