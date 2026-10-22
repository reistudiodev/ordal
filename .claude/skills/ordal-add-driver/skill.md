---
name: "ordal-add-driver"
description: "Use when adding or changing a database driver (MySQL, Postgres, MongoDB, Redis, or new) in the ordal Rust core."
---

# Adding a database driver to ordal

Layout: Rust core crate `ordal-core` in `core/` (Cargo workspace), exposed to Swift via UniFFI (proc-macro style). Swift package in `swift/`, apps in `apps/macos`, `apps/windows`, `apps/linux`.

## Steps
1. Put each driver in its own module: `core/src/drivers/<name>.rs`, behind a Cargo feature named after the database.
2. Implement the shared driver trait (connect, disconnect, ping, list schemas/collections/keys, run query, stream results in pages, cancel). Relational drivers return rows/columns; document stores return JSON documents; key-value stores return typed key/value entries.
3. Prefer async, pure-Rust crates: sqlx (MySQL, Postgres), the official mongodb crate, redis-rs. Run everything on the core's tokio runtime, never on the UI thread.
4. Stream large results in pages; never load a whole table into memory.
5. Map driver errors into the core's single error enum with a user-readable message.
6. Expose only UniFFI-safe types (records, enums, objects) across the boundary. Keep the FFI surface small and stable.
7. Regenerate bindings with `scripts/build-core.sh` (or `.ps1` on Windows). Do not set `strip = true` in the release profile; it removes UniFFI metadata.
8. Add unit tests, plus integration tests against Docker containers of the database, skipped when Docker is unavailable.
9. Never log passwords or connection strings. Store credentials in the OS keychain (Keychain, Windows Credential Manager, libsecret).

## Done when
`cargo test` passes, the bindings regenerate, and the macOS app can connect, browse and run a query against the new database.