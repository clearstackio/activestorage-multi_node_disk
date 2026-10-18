# frozen_string_literal: true

# `rake` is the whole local check: the suite, StandardRB and the RBS syntax.
require "bundler/setup"
require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "standard/rake"

RSpec::Core::RakeTask.new(:spec)

desc "Parse the RBS signatures in sig/"
task :rbs do
  sh "rbs", "parse", *Dir["sig/**/*.rbs"]
end

task default: %i[spec standard rbs]
