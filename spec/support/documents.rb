# frozen_string_literal: true

module Documents
  BYTES = "id,name\n1,Ada\n2,Grace\n"

  # A document whose file was uploaded to this node (node-a).
  def document_with_file(bytes = BYTES, filename: "members.csv")
    Document.create!(title: "d").tap { |document| document.file.attach(io: StringIO.new(bytes), filename: filename, content_type: "text/csv") }
  end

  # The token :token mode compares against, for the example's duration.
  def with_token(token = "node-secret", **overrides, &)
    ActiveStorage::MultiNodeDisk.with_config(auth: :token, token: token, **overrides, &)
  end
end

RSpec.configure { |config| config.include Documents }
