# Test boundary

## Ownership

- Mirror production ownership under `Unit`, place cross-boundary behavior under `E2E`, and keep architecture and performance coverage in their dedicated suites.
- Keep fixtures and test support owned by the narrowest suite that exercises their contract.

## Dependencies and boundary

- Test through the owning domain's public or internal test surface; do not make production ownership ambiguous solely to simplify a test.
- Do not use external network services. An isolated loopback listener is allowed only to prove that hostile renderer content makes zero requests.
- Create unique temporary directories and stores, clean them up, and never read, write, migrate, or delete real user documents or recovery data.

## State and invariants

- Prefer `ManualSyncScheduler`, injected executors, hooks, continuations, and explicit terminal-state waits over wall-clock sleeps or timing assumptions.
- Keep fixtures deterministic and repository-local, and assert durable ordering, token rejection, fail-closed behavior, and exactly-once completion where those contracts apply.
- Add or update architecture fixtures when introducing or tightening a dependency, ownership, or scoped-instruction rule.

## Verification

- Run the narrowest owning suite. Run `Tests/Architecture/run-tests.sh` for architecture-guard or scoped-instruction changes.
