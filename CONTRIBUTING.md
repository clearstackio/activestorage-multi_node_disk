# Contributing

Thanks for working on activestorage-multi_node_disk. Read
[AGENTS.md](AGENTS.md) first: it is the source of truth for the gem's scope,
shape and rules, for people and coding agents alike.

Open an issue before a large change, so we can agree on the shape first.
Pull requests need a green CI and a CHANGELOG line for anything a host would
notice.

## Setup

Tools are pinned in `mise.toml` (Ruby 4.0.7; the gem supports 3.3+).

```sh
bin/setup           # mise install, bundle install, rake
```

## Running the checks

```sh
bundle exec rake                       # specs, StandardRB, RBS syntax
bundle exec rspec spec/requests        # one folder
DATABASE_URL=postgres://user:pw@127.0.0.1/scratch bundle exec rspec   # on PostgreSQL
DATABASE_URL=trilogy://root:pw@127.0.0.1:3306/scratch bundle exec rspec  # on MySQL 8
```

Without `DATABASE_URL` the dummy app (`spec/dummy`) uses SQLite. Use a scratch
database only: the suite creates and drops tables.

## Gem conventions

Current RubyGems and Bundler practice, as applied here:

- **gemspec:** name, version from `lib/active_storage/multi_node_disk/version.rb`,
  summary, description, homepage, MIT, `required_ruby_version >= 3.3`;
  metadata `homepage_uri`, `source_code_uri`, `changelog_uri`,
  `bug_tracker_uri`, `documentation_uri`, `rubygems_mfa_required` and
  `allowed_push_host` (rubygems.org); `spec.files` from `git ls-files`
  without specs, sigs, `bin/` and dot files.
- **Dependencies:** runtime only `activestorage`, `actionpack`, `railties`
  (`>= 8.1, < 9`); development gems in the Gemfile. `Gemfile.lock` is
  committed (Bundler's current guidance). Dependabot proposes updates weekly.
- **Code:** `lib/activestorage-multi_node_disk.rb` (Bundler's auto-require)
  requires `active_storage/multi_node_disk`, which sets up
  `Zeitwerk::Loader.for_gem_extension(ActiveStorage)`; the service file is
  left to Active Storage's Configurator. `# frozen_string_literal: true`
  everywhere; one concern per file; a header comment on every class; YARD on
  public methods. RBS signatures in `sig/` (`rake rbs` checks the syntax; a
  full type check needs Rails signatures).
- **Style:** StandardRB, targeting Ruby 3.3 (`.standard.yml`); no
  `.rubocop.yml`.
- **Versions:** SemVer from 0.1.0; [Keep a Changelog](CHANGELOG.md): add a
  line under `[Unreleased]` for anything a host would notice.
- **CI:** GitHub Actions (`.github/workflows/ci.yml`): `rake` on Ruby 3.3,
  3.4 and 4.0, then the suite on PostgreSQL 17 and MySQL 8. Actions are
  pinned to commit SHAs. Oracle is not run in CI: the audit migration is
  rendered and its names checked by the suite.
- **Security:** no secrets in the repo; see [SECURITY.md](SECURITY.md).

## Releasing

Releases go to rubygems.org from GitHub Actions with
[trusted publishing](https://guides.rubygems.org/trusted-publishing/) (no
API key) and a Sigstore attestation (`.github/workflows/release.yml`, in the
`rubygems` environment).

Before the first release, an owner of the gem adds a pending trusted
publisher on rubygems.org (Profile → Trusted publishers): gem
`activestorage-multi_node_disk`, repository owner `clearstackio`, repository
`activestorage-multi_node_disk`, workflow `release.yml`, environment
`rubygems`. After the first push it becomes the gem's trusted publisher.

1. Update `VERSION` in `lib/active_storage/multi_node_disk/version.rb` and
   run `bundle install` so `Gemfile.lock` follows.
2. Move the `[Unreleased]` entries in `CHANGELOG.md` under the new version
   and date, and update the compare links at the bottom.
3. Commit, then tag and push: `git tag v0.1.0 && git push origin master v0.1.0`.

The workflow checks the tag matches `VERSION`, runs `rake`, then builds,
pushes and attests the gem.

## Tests

Every behaviour gets a spec: the service against fake nodes
(`spec/active_storage/service`), the endpoint and routing (`spec/requests`),
configuration, audit and the generator (`spec/active_storage/multi_node_disk`,
`spec/generators`). Specs test behaviour, not layout. Multi-node behaviour
uses `ActiveStorage::MultiNodeDisk::TestHelper`, never the network.
