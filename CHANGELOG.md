# Changelog

All notable changes to activestorage-multi_node_disk are listed here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project uses [Semantic Versioning](https://semver.org/). Before 1.0, a
minor version may change public APIs; each entry says how.

## [Unreleased]

### Fixed

- The audit migration from `install --audit` now finishes a run that stopped
  part way: each statement has its own guard (`table_exists?`,
  `index_exists?`), so a table left without its index gets the index, and on
  Oracle an empty table left without its sequence is dropped and recreated.
  Hosts that already ran the migration need not change anything.

## [0.1.0] - 2026-10-20

The first release.

### Added

- `ActiveStorage::Service::MultiNodeDiskService` (`service: MultiNodeDisk`), a
  Disk service for several nodes: uploads stay on the receiving node's disk;
  reads, `exist?` and deletes ask the other nodes (`nodes:`) in parallel under
  one deadline, and the first copy that matches the blob's size and checksum
  wins. No migration, no metadata, no backfill.
- A node endpoint (`/rails/active_storage/multi_node_disk/blobs/:key`, `GET`,
  `HEAD`, `DELETE`) in an isolated engine, mounted under Active Storage's
  routes prefix ahead of the app's routes (`draw_routes`). It serves its own
  disk only, so a hop never fans out.
- Request authentication: `auth` `:none` (default, with a boot warning in
  production), `:token` (Bearer, `secure_compare`), `:ip` (the nodes' DNS
  addresses with a 60-second cache, or IPs/CIDRs) and `[:ip, :token]`.
- Errors that subclass Active Storage's: `NotHere`, `Unavailable`,
  `Mismatch`; `error_mapper` for host classes.
- Delete modes: `:sync` (raises `Unavailable` for a node that did not
  confirm) and `:job` (`DeleteJob`, retried, idempotent; Active Job optional).
- Audit: one versioned JSON document per answered request and per remote
  fetch or delete, to a JSON Lines file (default), a table, nowhere or a
  callable; `audit_requester`, `audit_context`, `with_requester` and the
  requester header; `audit.multi_node_disk` events.
- `bin/rails g active_storage:multi_node_disk:install [--audit]`: the
  initializer and the audit table's migration (PostgreSQL, MySQL 8, Oracle,
  SQLite; names within 30 characters; `table_name_prefix`).
- `ActiveStorage::MultiNodeDisk::TestHelper`: fake nodes answered by the real
  endpoint in process.

[Unreleased]: https://github.com/clearstackio/activestorage-multi_node_disk/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/clearstackio/activestorage-multi_node_disk/releases/tag/v0.1.0
