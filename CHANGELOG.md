# Changelog

All notable changes to activestorage-multi_node_disk are listed here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project uses [Semantic Versioning](https://semver.org/). Before 1.0, a
minor version may change public APIs; each entry says how.

## [Unreleased]

## [0.1.1] - 2026-11-10

### Security

- Development dependencies take their patched releases: Rails 8.1.4.1
  (including Active Storage, for GHSA-f3w6-w445-fwh9), Rack 3.2.8, Nokogiri
  1.19.7, Loofah 2.25.3, Crass 1.0.8, rails-html-sanitizer 1.7.2, Addressable
  2.9.2, sqlite3 2.10.2 and Trilogy 2.13.3. The gem's runtime requirement
  (`activestorage >= 8.1, < 9`) is unchanged; hosts should update Rails
  themselves.

### Changed

- Development uses Ruby 4.0.9 and Bundler 4.0.24. CI pins
  `ruby/setup-ruby` v1.338.0 and its PostgreSQL 17 and MySQL 8.0 service
  images by digest.

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

[Unreleased]: https://github.com/clearstackio/activestorage-multi_node_disk/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/clearstackio/activestorage-multi_node_disk/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/clearstackio/activestorage-multi_node_disk/releases/tag/v0.1.0
