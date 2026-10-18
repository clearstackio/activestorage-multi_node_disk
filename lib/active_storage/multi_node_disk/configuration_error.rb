# frozen_string_literal: true

module ActiveStorage
  module MultiNodeDisk
    # A hook is missing or of the wrong kind (raised at boot).
    class ConfigurationError < StandardError; end
  end
end
