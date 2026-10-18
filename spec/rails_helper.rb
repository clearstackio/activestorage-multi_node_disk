# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "dummy/config/environment"
require "spec_helper"
require "rspec/rails"
require "webmock/rspec"
require "active_storage/multi_node_disk/test_helper"

ActiveRecord::Migration.verbose = false
load File.expand_path("dummy/db/schema.rb", __dir__)
Dir[File.join(__dir__, "support/**/*.rb")].sort.each { |file| require file }

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.include ActiveStorage::MultiNodeDisk::TestHelper
  config.include ActiveJob::TestHelper
  config.after { FileUtils.rm_rf(Rails.root.join("tmp/storage")) }
end
