# activestorage-multi_node_disk

An Active Storage Disk service for Rails apps that run on several nodes, each with its own disk.

A file stays on the disk of the node that received it. Any node can read, check or delete it: the service looks on its own disk first, then asks the other nodes and keeps the first copy that matches the blob. Zero migration by default: nothing is recorded, so existing blobs work as they are.

[![Build Status](https://github.com/clearstackio/activestorage-multi_node_disk/actions/workflows/ci.yml/badge.svg)](https://github.com/clearstackio/activestorage-multi_node_disk/actions)

## Installation

Add this line to your application’s Gemfile:

```ruby
gem "activestorage-multi_node_disk"
```

## Getting Started

Replace `service: Disk` with `service: MultiNodeDisk` and list the nodes:

```yml
local:
  service: MultiNodeDisk
  root: <%= Rails.root.join("storage") %>
  nodes: [app1.internal, app2.internal, app3.internal]
```

Give the nodes a shared token and turn on token checks:

```sh
bin/rails credentials:edit   # multi_node_disk: { token: <the same random value on every node> }
```

```ruby
# config/initializers/active_storage_multi_node_disk.rb
ActiveStorage::MultiNodeDisk.configure do |config|
  config.auth = :token
end
```

That’s it. `bin/rails g active_storage:multi_node_disk:install` writes that initializer for you.

> **Warning:** the endpoint checks nothing by default (`auth = :none`): anyone who can reach a node can read and delete its files. Use `:token` (or `[:ip, :token]`) anywhere but a closed network. The gem logs a warning at boot in production while it is `:none`.

## How It Works

- **Upload** - written to this node’s disk, exactly as Disk
- **Read** (`download`, `download_chunk`, `open`) - this disk first; else every other node is asked at once, under one deadline (`open_timeout + read_timeout`), and the first copy whose size and checksum match the blob wins. A copy that does not match is skipped
- **`exist?`** - this disk, else whether any node has the file (presence, as Disk)
- **Delete** - this disk, then every other node; a 404 counts as done
- **The endpoint** - each node answers other nodes at `/rails/active_storage/multi_node_disk/blobs/:key` (`GET`, `HEAD`, `DELETE`), from its own disk only. A request that arrives from another node never fans out again

A whole-file `download` is also checked against the blob’s size and checksum when the file is local, and `open` keeps Rails’ own check.

Local only, as Disk: `url` (use Active Storage’s proxy mode, which reads through `download`), `compose` and `delete_prefixed` (variants, which any node can regenerate). Keys with no blob row (variants) are never looked for elsewhere.

### Cost

A local hit costs a `File.exist?` (plus one indexed blob lookup for a whole-file `download`). A miss on N nodes sends N - 1 requests, at most 8 at a time per call; only the node with the file sends it, the others answer 404 after a `File.exist?`. A delete always sends N - 1 requests.

## Errors

The service raises subclasses of Active Storage’s own errors, so Rails keeps handling them:

Error | Superclass | When
--- | --- | ---
`ActiveStorage::MultiNodeDisk::NotHere` | `ActiveStorage::FileNotFoundError` | every node answered "not here"
`ActiveStorage::MultiNodeDisk::Unavailable` | `ActiveStorage::Error` | a node that may have it did not answer (retry)
`ActiveStorage::MultiNodeDisk::Mismatch` | `ActiveStorage::IntegrityError` | the only copies found do not match the blob

Each has `nodes`, `key` and `filename`. When no copy wins: any node failed → `Unavailable`; else a wrong copy → `Mismatch`; else `NotHere`.

## Deletes

`delete_mode` decides how a delete reaches the other nodes; the local copy is always deleted at once.

- `:sync` (default) - inline, after which `Unavailable` names any node that did not confirm (as other services raise on a failed delete). Rails’ `purge` removes the rows first, so the rows are gone either way
- `:job` - `ActiveStorage::MultiNodeDisk::DeleteJob`, retried while a node does not confirm, idempotent. Needs Active Job (checked at boot)

Rails’ `purge_later` already runs `purge` in `ActiveStorage::PurgeJob`; with `:job`, that job deletes the local copy and queues `DeleteJob` for the rest.

```ruby
config.delete_mode = :job
config.delete_job_queue = :maintenance        # default: Active Storage's purge queue
config.delete_job_class = "FileDeleteJob"     # a subclass, for other retries
```

## Request Authentication

`auth` | The endpoint needs
--- | ---
`:none` (default) | nothing
`:token` | `Authorization: Bearer <token>`; else 401 with `WWW-Authenticate: Bearer realm="Multi-node disk"`
`:ip` | the caller in `allowed_ips`; else 403
`[:ip, :token]` | both (the address is checked first)

Outgoing calls send the Bearer token only under `:token`.

`allowed_ips` defaults to every node’s addresses, resolved by DNS and resolved again every 60 seconds (a node that fails to resolve keeps its last addresses). Set it to IPs or CIDRs to override. The caller is the socket’s peer; `X-Forwarded-For` counts only when that peer is listed in `config.action_dispatch.trusted_proxies`, so set it to your proxies when one sits in front of the app.

The gem checks who is calling, never who may see a file: that is your app’s business, on its own pages.

## Audit

Every answered request (served, refused, deleted) and every remote fetch or delete is one JSON document:

```json
{"v":1,"at":"2026-10-17T12:00:00.000Z","action":"read","result":"served","status":200,"key":"abc","filename":"members.csv",
 "byte_size":22,"node":"app2","from_node":"app1","remote_ip":"10.0.0.1","auth":["token"],"identity":"node","hop":true,
 "duration_ms":3.1,"requester":{"id":42,"label":"hr@example.com","type":"hr_admin"},"requester_verified":true,"context":{"source_id":7}}
```

`action` is `read`, `head`, `delete`, `fetch` or `remote_delete`; `result` is `served`, `deleted`, `not_found`, `mismatch`, `unauthorized`, `forbidden` or `error`. It never holds a token, file contents or a signed URL. The same document is instrumented as `audit.multi_node_disk`.

`audit` | Where
--- | ---
`:file` (default) | a JSON line appended to `audit_path` (`tmp/multi_node_disk/audit.log`), whole lines across threads and processes. Rotate it with logrotate (`copytruncate`), or rename it: the next write starts a new file
`:table` | a row in `multi_node_disk_audits` (`id`, `created_at`, `payload`); run `bin/rails g active_storage:multi_node_disk:install --audit` and migrate
`:none` | nowhere
a callable | `->(entry) { ... }`

A sink that fails is logged and never fails the request.

### Who it is for

```ruby
config.audit_requester = ->(request) { {id: Current.user&.id, label: Current.user&.email, type: "staff"} }
config.audit_context = ->(request, entry) { {record: Upload.find_by_blob_key(entry[:key])&.id} }
```

Work that serves no request (a job) names the requester for a block:

```ruby
ActiveStorage::MultiNodeDisk.with_requester(id: user.id, label: user.email) do
  blob.open { |file| import(file) }
end
```

The requester is sent to the node that answers (`X-Multi-Node-Disk-Requester`, JSON, at most 1 KB; larger is dropped) and recorded there; that node marks it `requester_verified: true` only when a check (`:token` or `:ip`) passed. Never put a secret in it.

### The audit table

The generator writes a migration named `CreateActiveStorageMultiNodeDiskAudits`; nothing runs on its own. It is safe to run twice and reversible.

Database | `payload` | Tested
--- | --- | ---
PostgreSQL | `jsonb` | suite
MySQL 8 | `json` | suite
SQLite | `text` | suite
Oracle | CLOB (`text`) | migration rendered and names checked; not run

The only index is on `created_at` (`i_mnd_audits_created_at`), for pruning. Every name fits Oracle’s 30 characters. `table_name_prefix` (default `multi_node_disk_`) changes the table and index names.

## Testing Your App

```ruby
RSpec.configure { |config| config.include ActiveStorage::MultiNodeDisk::TestHelper }

it "reads a file another node holds" do
  node_b = multi_node_disk_node("app2")
  multi_node_disk_move(blob, to: node_b)

  multi_node_disk_cluster("app2" => node_b, "app3" => :missing) do |requests|
    expect(blob.download).to eq(bytes)
  end
end
```

A node in the cluster is a service (answered by the gem’s real endpoint, in process), `:missing`, `:wrong`, `:timeout` or `:down`. `requests` lists method, node, URL and header names, never values.

## Advanced

Set hooks once, in an initializer. A hook is a value or anything that responds to `call`. The configuration is validated and frozen after boot.

Option | Default | Notes
--- | --- | ---
`nodes` | `nodes:` in storage.yml | `Array` or `-> Array`; this node may be in it
`current_node` | `Socket.gethostname` | `node:` in storage.yml wins
`url_for` | `->(node, key) { "https://#{node}/rails/active_storage/multi_node_disk/blobs/#{key}" }` | must return `https:`
`auth` | `:none` | per service in storage.yml too
`allowed_ips` | nodes’ DNS addresses | per service in storage.yml too
`token` | credentials `multi_node_disk.token` | what `:token` compares against
`token_for` | `->(node, blob, action) { token }` | the token sent; `blob` is nil for a delete after the rows went
`authenticate` | `->(token, request) { :node if token matches }` | returns an identity label, or nil to refuse
`http_client` | `ActiveStorage::MultiNodeDisk::NetHttpClient` | `call(method, url, headers:, node:, open_timeout:, read_timeout:)` → `Response(status, body, headers)`; called from several threads at once
`open_timeout`, `read_timeout` | 3, 20 | seconds; per service in storage.yml too
`hop_header` | `X-Multi-Node-Disk-Hop` | carries the calling node’s name
`requester_header` | `X-Multi-Node-Disk-Requester` |
`error_mapper` | `->(error) { error }` | raise your own classes (subclass the gem’s)
`delete_mode`, `delete_job_queue`, `delete_job_class` | `:sync`, purge queue, `DeleteJob` |
`audit`, `audit_path`, `audit_context`, `audit_requester` | `:file`, `tmp/multi_node_disk/audit.log`, nil, nil | `audit_context(request or nil, entry)`, `audit_requester(request or nil)`
`table_name_prefix` | `multi_node_disk_` |
`draw_routes` | `true` | mounts the endpoint under Active Storage’s routes prefix, ahead of your routes; independent of `config.active_storage.draw_routes`

Events (`ActiveSupport::Notifications`): `fetch`, `exist`, `delete`, `mismatch`, `serve`, `denied`, `audit` and `delete_abandoned`, each `.multi_node_disk`, plus Active Storage’s own `service_*.active_storage`.

### Security

- Keep the token in credentials or your secrets store; `filter_parameters` does not cover headers, so keep `Authorization` out of request logs and APM
- Under `:token`, `url_for` must point at HTTPS (checked before a token is sent)
- See [SECURITY.md](SECURITY.md)

### A full example

The host this gem was written for runs three nodes behind per-node proxies, with its own HTTP client, named API tokens and audit table:

```ruby
ActiveStorage::MultiNodeDisk.configure do |config|
  config.auth = :token
  config.url_for = ->(node, key) { "https://#{App.public_host}#{App.prefix}#{ActiveStorage::MultiNodeDisk.mount_path}/blobs/#{key}" }
  config.token_for = ->(node, blob, action) { NodeFiles.token_for(blob) }
  config.authenticate = ->(token, request) { NodeFiles.caller_for(token) }
  config.http_client = NodeFiles::Client.new   # HTTPX, pinned to each node's IPv4 addresses
  config.hop_header = "X-App-File-Hop"
  config.error_mapper = ->(error) { NodeFiles.app_error(error) }
  config.delete_mode = :job
  config.delete_job_queue = :maintenance
  config.audit = :table
  config.audit_requester = ->(request) { NodeFiles.requester(request) }
  config.audit_context = ->(request, entry) { NodeFiles.context(entry) }
end
```

## Requirements

Ruby | Rails | Databases (audit table)
--- | --- | ---
3.3+ | 8.1 | PostgreSQL, MySQL 8, Oracle, SQLite

No runtime dependencies beyond Rails.

## History

View the [changelog](CHANGELOG.md)

## Contributing

Everyone is encouraged to help improve this project. Here are a few ways you can help:

- [Report bugs](https://github.com/clearstackio/activestorage-multi_node_disk/issues)
- Fix bugs and [submit pull requests](https://github.com/clearstackio/activestorage-multi_node_disk/pulls)
- Write, clarify, or fix documentation
- Suggest or add new features

To get started with development, see [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately, as [SECURITY.md](SECURITY.md) explains.

## License

MIT. See [LICENSE](LICENSE).
