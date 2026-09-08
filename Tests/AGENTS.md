# Test execution constraints

- Do not test statically defined values whose correctness is already established by their source or type declaration. Test the observable behavior that consumes them only when that behavior has meaningful regression risk.
- When logic is deleted, do not add negative tests that merely prove the removed path no longer exists. Cover only the observable replacement behavior or contract that could realistically regress.
- Unit, E2E, and Performance compile into separate targets. Keep support in the narrowest owning suite; Unit helpers are not automatically available to E2E or Performance. Keep fixtures deterministic and repository-local.
- Do not use external network services. Isolated loopback listeners are allowed only to prove hostile renderer content makes zero requests.
- Inject unique temporary document directories/recovery stores and clean them up. Never access real user documents in tests or mutate/clean up the production shared recovery store.
- Drive races with `ManualSyncScheduler`, injected executors, hooks, continuations, or terminal-state waits. Assert the intended interleaving and outcome instead of relying on elapsed sleeps.
- Performance selectors use `DarthScriptumPerformanceTests/<Class>[/<Method>]` and run in `Benchmark`, not Debug. Use `./scripts/perf-audit.sh` for the edit-pipeline audit; ordinary `--all` runs exclude performance.
- Add architecture fixtures when changing enforced dependency/scope rules. `Tests/Architecture/run-tests.sh` also checks Xcode suite ownership, schemes, and test routing with a stubbed `xcodebuild`; it does not compile the app.
