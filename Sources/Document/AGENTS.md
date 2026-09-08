# Synchronization and durability

- Apply coordinator events serially. Executors perform immutable requests without selecting synchronization policy. Echo complete effect tokens and reject stale revisions, attachment epochs, or attempts before changing state.
- Run blocking document work through its injected `DocumentFileAccessLane`; recovery stores share the `DocumentFileAccess.recovery` FIFO lane. Do not serialize unrelated documents through recovery or move blocking I/O into `Task`/`Task.detached`. Synchronous access exists for AppKit worker callbacks, never the main thread or a Swift cooperative executor.
- Durable baselines, attachment identity, commit generations, recovery records, and cleanup receipts are evidence, not values to reconstruct from current editor text. Preserve codec/commit contracts tying snapshots and fingerprints to the same bytes and target.
- Commit durable evidence before publishing in-memory success. Fail closed when attachment, baseline, commit, recovery generation, record ownership, or cleanup safety is unproven; retain raw evidence.
- Recovery schema/journal changes must survive restart and interrupted deletion/migration. Preserve unknown future schemas, malformed records, and incomplete raw payload/metadata pairs instead of silently skipping/deleting them. Exercise disk interruption hooks and reopen the store in durability tests.
