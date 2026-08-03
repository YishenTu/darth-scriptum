# Test boundary

- Mirror production ownership under `Unit`, place cross-boundary behavior under `E2E`, and keep architecture and performance coverage in their dedicated suites.
- Prefer `ManualSyncScheduler`, injected executors, hooks, continuations, and explicit terminal-state waits over wall-clock sleeps or timing assumptions.
- Create unique temporary directories and stores, clean them up, and never read, write, migrate, or delete real user documents or recovery data.
- Do not use external network services; an isolated loopback listener is allowed only to prove that hostile renderer content makes zero requests.
- Keep fixtures deterministic and repository-local, and assert durable ordering, token rejection, fail-closed behavior, and exactly-once completion where those contracts apply.
