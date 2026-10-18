# frozen_string_literal: true

require "rails_helper"
require "generators/active_storage/multi_node_disk/install_generator"

# The generator writes the host's migration; the dummy app runs it.
RSpec.describe ActiveStorage::MultiNodeDisk::InstallGenerator do
  let(:destination) { Dir.mktmpdir("multi_node_disk-generator-") }

  after { FileUtils.rm_rf(destination) }

  def generate(*args)
    described_class.start(args, destination_root: destination, quiet: true)
    Dir[File.join(destination, "db/migrate/*.rb")].first
  end

  def load_migration(file)
    load file
    CreateActiveStorageMultiNodeDiskAudits.new
  end

  it "writes the initializer, and the audit migration only with --audit" do
    expect(generate).to be_nil
    expect(File.read(File.join(destination, "config/initializers/active_storage_multi_node_disk.rb"))).to include("ActiveStorage::MultiNodeDisk.configure")
    expect(generate("--audit")).to end_with("_create_active_storage_multi_node_disk_audits.rb")
  end

  context "when the migration runs" do
    # DDL commits on MySQL and Oracle: no wrapping transaction here.
    self.use_transactional_tests = false

    after do
      ActiveStorage::Attachment.delete_all
      ActiveStorage::Blob.delete_all
      Document.delete_all
    end

    it "creates the table the :table sink writes to, safely twice, and drops it" do
      migration = load_migration(generate("--audit"))
      connection = ActiveRecord::Base.connection
      migration.migrate(:up)
      migration.migrate(:up)

      path = "/rails/active_storage/multi_node_disk/blobs/#{document_with_file.file.blob.key}"
      ActiveStorage::MultiNodeDisk.with_config(audit: :table) { Rails.application.call(Rack::MockRequest.env_for(path)) }
      expect(ActiveStorage::MultiNodeDisk::Audit.last.payload).to include("action" => "read", "v" => 1)
      expect(connection.indexes(:multi_node_disk_audits).map(&:name)).to eq(["i_mnd_audits_created_at"])

      migration.migrate(:down)
      expect(connection.table_exists?(:multi_node_disk_audits)).to be(false)
    ensure
      migration&.migrate(:down)
    end
  end

  {"PostgreSQL" => :jsonb, "Mysql2" => :json, "Trilogy" => :json, "OracleEnhanced" => :text, "SQLite" => :text}.each do |adapter, type|
    it "stores the payload as #{type} on #{adapter}" do
      migration = load_migration(generate("--audit"))
      allow(migration).to receive(:connection).and_return(double(adapter_name: adapter))
      expect(migration.send(:payload_type)).to eq(type)
    end
  end

  it "names every table and index within Oracle's 30 characters" do
    source = File.read(generate("--audit"))
    names = source.scan(/TABLE = :(\w+)|INDEX = "(\w+)"/).flatten.compact

    expect(names).to contain_exactly("multi_node_disk_audits", "i_mnd_audits_created_at")
    expect(names.map(&:length)).to all(be <= 30)
    expect("#{names.first}_seq".length).to be <= 30 # the sequence Oracle's adapter adds
  end

  it "follows a different table prefix" do
    ActiveStorage::MultiNodeDisk.with_config(table_name_prefix: "files_") do
      expect(File.read(generate("--audit"))).to include("TABLE = :files_audits", 'INDEX = "i_f_audits_created_at"')
    end
  end
end
