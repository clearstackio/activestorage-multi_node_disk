# frozen_string_literal: true

require_relative "lib/active_storage/multi_node_disk/version"

Gem::Specification.new do |spec|
  spec.name = "activestorage-multi_node_disk"
  spec.version = ActiveStorage::MultiNodeDisk::VERSION
  spec.authors = ["Ajaya Agrawalla"]
  spec.email = ["ajaya@clearstack.io"]
  spec.summary = "An Active Storage Disk service for apps on several nodes, each with its own disk"
  spec.description = "Stores each file on the disk of the node that received it. Any node can read, check or " \
    "delete it: the service looks on its own disk first, then asks the other nodes. No database needed."
  spec.homepage = "https://github.com/clearstackio/activestorage-multi_node_disk"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "#{spec.homepage}/tree/main",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "documentation_uri" => "#{spec.homepage}#readme",
    "rubygems_mfa_required" => "true",
    "allowed_push_host" => "https://rubygems.org"
  }

  # Files known to git, without the suite, CI and development tooling.
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |file|
      file.start_with?(*%w[bin/ spec/ sig/ .]) || %w[Gemfile Gemfile.lock Rakefile mise.toml AGENTS.md].include?(file) ||
        file == File.basename(__FILE__)
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "activestorage", ">= 8.1", "< 9"
  spec.add_dependency "actionpack", ">= 8.1", "< 9"
  spec.add_dependency "railties", ">= 8.1", "< 9"
end
