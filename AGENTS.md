# activestorage-multi_node_disk — instructions for coding agents

activestorage-multi_node_disk is an ActiveStorage service for Rails 8.1 that
replaces the local Disk service on apps running on several nodes. A file is
stored on the disk of the node that received it. Any node can read or delete
it: the service checks the local disk first, then asks the other nodes. It
needs no database by default.

This file is the only agent instruction file for the repo. Do not add
tool-specific instruction files (`CLAUDE.md`, Copilot or Cursor rules).

## Scope: what the gem does and does not do

- **The gem does:** request authentication on its own routes, serving and
  deleting files across nodes, and auditing those requests.
- **The gem does not:** know about users, groups, policies or permissions.
  Deciding who may see a file belongs to the host app (one host, for
  example, grants every file of a record to anyone with access to that
  record).
- **Defaults are what a stock Rails 8.1 app uses:**
  - `Net::HTTP` and system DNS
  - `ActionController::HttpAuthentication::Token` with Rails credentials
  - `Socket.gethostname` as the node name
  - ActiveStorage's own checksum checks and `instrument`
  - configuration in `storage.yml`

  There are no runtime dependencies beyond `rails`/`activestorage`. Anything
  else (HTTPX, IPv4 pinning, app settings and secrets, custom URLs, identity,
  audit enrichment, error mapping) is a host override in the host's
  initializer.
- **Generic but opinionated:** the gem works out of the box with minimal
  config and one documented way of doing things. Add a hook only where a real
  host differs. YAGNI everything else.

## Shape: extend ActiveStorage, do not wrap it

- One service class, `ActiveStorage::Service::MultiNodeDiskService <
  ActiveStorage::Service::DiskService`, in
  `lib/active_storage/service/multi_node_disk_service.rb`. ActiveStorage's
  Configurator resolves it from `service: MultiNodeDisk`, the same way it
  resolves Disk and S3.
- Override only the reads (`download`, `download_chunk`, `exist?`), `delete`,
  `open` (Rails' integrity failure becomes the gem's `Mismatch`) and `upload`
  (only so Disk's cleanup of a failed checksum deletes locally, never on the
  other nodes). Call `super` for local work. `url`, `compose`,
  `delete_prefixed` (variants, regenerable on any node) and everything else
  behave exactly like Disk: local.
- Helpers (node client, fan-out, controllers, audit) live under
  `ActiveStorage::MultiNodeDisk::`. No parallel "adapter" layer.
- Host setup is one changed line in `storage.yml` (`service: MultiNodeDisk`
  plus `nodes:`) and one initializer
  (`ActiveStorage::MultiNodeDisk.configure { |c| ... }`).
- Gem name `activestorage-multi_node_disk`. Entry file
  `lib/activestorage-multi_node_disk.rb` only does
  `require "active_storage/multi_node_disk"`.

## Behaviour

- **Discovery mode (default; no database):**
  - Read: the local disk first, then every other configured node, asked in
    parallel with a bounded pool and an overall deadline. The first answer
    whose size and checksum match the blob wins. A mismatched answer is
    skipped and reported.
  - Delete: the local copy, then every other node. A 404 counts as success.
  - Upload: local disk only, as Disk does.
  - A request that arrives as a hop is served from local disk only and never
    fans out.
  - The only required setting is the node list (static in `storage.yml`, or a
    callable).
- **Recorded-node mode:** dropped (YAGNI): saving a few 404s on stages of
  three to five nodes did not earn a write on every upload and a backfill.
- **Remote delete mode:**
  - `:sync` (default) deletes inline and reports the result to the caller.
  - `:job` runs remote deletes in `ActiveStorage::MultiNodeDisk::DeleteJob`,
    with a configurable queue and retries, and is idempotent. ActiveJob is
    optional: lazy-loaded, with boot validation.
  - The local copy is always deleted synchronously. Keep ActiveStorage's own
    `purge` / `purge_later` model.

## Routes

- The gem's routes live on their own clean root under
  `config.active_storage.routes_prefix`, for example
  `/rails/active_storage/multi_node_disk/blobs/:key` (GET/HEAD to read,
  DELETE to delete).
- They are drawn by an `isolate_namespace` engine,
  `ActiveStorage::MultiNodeDisk::Engine`, mounted automatically
  (`routes.prepend`, so a host catch-all cannot hide it) under the gem's own
  `draw_routes` switch, independent of ActiveStorage's.
- Never add anything at `/`: no root route, no catch-all, no shadowing of
  host routes, and no `default_url_options` changes.

## Request authentication (configurable)

- `:none` is the **default**. The README warns about it, and the gem logs a
  warning at boot in production.
- `:token`: Rails `HttpAuthentication::Token` with Bearer tokens, compared
  with `secure_compare` against credentials or a host `authenticate` hook. A
  missing or wrong token returns 401 with `WWW-Authenticate`.
- `:ip`: an allowlist. It defaults to every node's IP, re-resolved from DNS on
  a TTL and cached in a thread-safe way. It can be overridden with IPs or
  CIDRs. The caller is the socket's peer; `request.remote_ip`
  (`X-Forwarded-For`) counts only when that peer is listed in the host's
  `config.action_dispatch.trusted_proxies` (Rails' own `remote_ip` would take
  a forwarded address any caller can write). A request from outside the list
  returns 403.
- `[:ip, :token]` requires both to pass.
- Outgoing requests send the Bearer token only when `:token` is configured.
- Never log tokens.

## Audit (modelled on Blazer's audits)

- **Sinks:**
  - `:file` (default): JSON Lines in `tmp/multi_node_disk/audit.log`. Writes
    are thread- and process-safe, and rotation is documented.
  - `:table`: opt-in.
  - `:none`.
  - Any callable.
- **One payload shape for every sink.** A versioned JSON document (`"v": 1`)
  holding:
  - time, action, result, HTTP status
  - blob key, plus filename and size when known
  - serving and requesting nodes, remote IP
  - auth mode, hop flag, duration
  - `requester` and `context`

  Never store tokens, file contents or signed URLs.
- **Requester context is decided by host config:**
  - The `audit_requester` hook supplies it.
  - `ActiveStorage::MultiNodeDisk.with_requester(ctx) { }` sets it for jobs
    (CurrentAttributes or fiber-local).
  - It is forwarded to other nodes in a size-capped header. The receiving
    node trusts it only after request auth passes; under `:none` it is
    recorded as unverified.
  - A typical host passes the requesting user.
- Every audit event is also sent as an `ActiveSupport::Notifications` event,
  `audit.multi_node_disk`.

## Tables and migrations

- **The audit table has no fixed column format:** `id`, `created_at` and one
  JSON `payload`, read with `attribute :payload, :json`. Never
  `serialize ... coder: JSON`.
- **Must work on MySQL, Oracle and PostgreSQL:**
  - The payload column is `jsonb` on PostgreSQL, `json` on MySQL 8, and CLOB
    on Oracle.
  - Never index the JSON column. The only default index is on `created_at`.
  - No adapter-specific SQL or JSON operators anywhere in the gem.
- **Naming:** every gem table shares one clear, configurable prefix
  (`c.table_name_prefix`, default `multi_node_disk_`:
  `active_storage_multi_node_disk_audits` would be 37 characters). Table, index and constraint names fit the
  strictest limit (Oracle 30 if pre-12.2, MySQL 64), and index names are set
  explicitly.
- **Migrations come only from the install generator**
  (`rails g active_storage:multi_node_disk:install [--audit]`):
  - named after the gem
  - reversible, and safe to re-run (`if_not_exists` or a `table_exists?`
    guard)
  - never run automatically
  - the gem never touches a host database the host hasn't opted into

## Configuration hooks

- Every host-specific value is a `configure` hook, either a callable or a
  plain value, with a safe default or boot validation. The hooks cover:
  - node identity and addresses
  - URLs
  - outgoing token and headers
  - incoming `authenticate`
  - transport (client, timeouts)
  - delete mode and job
  - audit sink, requester and context
  - callbacks and Notifications
  - error classes
- Config is validated at boot and frozen afterwards, so it is thread-safe.
- Ship a test helper (a fake multi-node setup) so hosts can spec their hooks.
- Document every hook in the README (signature, default, example), with
  "the one way" first and the hooks under an "Advanced" section.

## Gem conventions (2026)

- **House style:** an Ankane-style README, Keep a Changelog, MIT LICENSE,
  GitHub Actions CI, StandardRB, and the Ruby (`.ruby-version`) / Rails 8.1
  pins. CONTRIBUTING.md spells the conventions out.
- **gemspec:**
  - full metadata, including `rubygems_mfa_required`
  - bounded runtime dependencies only (`activestorage >= 8.1, < 9`)
  - `spec.files` from `git ls-files`
  - dev dependencies in the Gemfile
- **Code:**
  - Zeitwerk `for_gem_extension(ActiveStorage)`, the service file left to
    Active Storage's Configurator
  - `version.rb`
  - RBS in `sig/`
  - `# frozen_string_literal: true`
- **Versioning and release:**
  - SemVer from 0.1.0, with a Keep a Changelog CHANGELOG
  - `rake` runs the tests and lint
  - `bin/setup` and `bin/console`
- **Security:**
  - no secrets in the repo
  - releases go to rubygems.org from GitHub Actions only, with trusted
    publishing and a Sigstore attestation; never a manual `gem push`
  - third-party actions are pinned to a commit SHA, with least-privilege
    `permissions`
- **Distribution:**
  - the source lives at
    `https://github.com/clearstackio/activestorage-multi_node_disk`; the gem
    is published on rubygems.org
  - hosts consume a release from rubygems.org; to try unreleased work, use
    `git:` plus `bundle config local.activestorage-multi_node_disk <path>`,
    never a committed `path:` dependency

## Testing

- The gem has its own suite with a dummy Rails app, and simulates several
  nodes with stubbed HTTP. It covers:
  - local hit
  - second or third node wins
  - mismatch skipped
  - all nodes miss
  - a timeout while another node answers
  - hops never fanning out
  - sync and job deletes
  - every auth mode and status code
  - IP re-resolve
  - routes isolated under the prefix
  - audit sinks, requester forwarding, and no tokens in the audit
  - migration rendering per adapter, with a name-length check
- CI runs SQLite on every supported Ruby, plus PostgreSQL and MySQL 8.
  Oracle is rendered only. Report which databases were really exercised and which were only
  rendered.
- Specs test behaviour, not layout.

## Working rules

- Codex reviews every staged changeset before it is committed. Run it
  read-only, with no stdin:
  `timeout 900 codex exec --sandbox read-only -C <repo> "..." </dev/null`.
  Fix every P1 and P2 first.
- Commit named paths only (`git commit -- <paths>`). No AI wording or
  trailers in commits or files. Push only when the owner says so.
- Ask the owner once, with the options and a recommendation. In autonomous
  work, decide yourself and consult Codex when unsure.
- When adopting the gem in a host app, the host's own rules (its
  `AGENTS.md`) apply to that work.
