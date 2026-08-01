# Performance audit

The edit-pipeline audit measures the application-owned work required to turn a
one-character editor mutation into a new `SourceRevision`. It covers binding
reconciliation and `SourceEdit` application at three document sizes.

Run the reproducible arm64 Benchmark configuration with:

```sh
./scripts/perf-audit.sh
```

The test prints machine-readable `PERF_AUDIT` records and fails when the
captured-mutation p95 exceeds its size-specific budget:

| Workload | p95 budget |
| --- | ---: |
| 128 KiB | 1 ms |
| 1 MiB | 3 ms |
| 4 MiB | 8 ms |

## 2026-08-01 baseline and result

Environment: Apple M4, 24 GiB RAM, macOS 26.5.2, Xcode 26.4, arm64 Benchmark
configuration. Each result is the median or p95 of nine samples after two
warmups.

| Document | Before median | Before p95 | Captured edit median | Captured edit p95 | Median reduction |
| --- | ---: | ---: | ---: | ---: | ---: |
| 128 KiB | 0.881 ms | 0.893 ms | 0.008 ms | 0.009 ms | 99.1% |
| 1 MiB | 7.341 ms | 7.750 ms | 0.060 ms | 0.063 ms | 99.2% |
| 4 MiB | 28.696 ms | 29.421 ms | 0.236 ms | 0.245 ms | 99.2% |

“Before” is the legacy full-binding diff path used before the native text
mutation was captured. Both paths remain in the audit so future changes can be
compared on the same machine and the guarded fallback remains measurable.

This benchmark isolates application-owned edit reconciliation. MarkdownEngine
parsing, TextKit layout, rendering, and the secondary split pane are outside
its timing boundary and should be profiled separately when their dependency
APIs make incremental updates possible.
