# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/migration"

module Passkit
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("../../templates", __FILE__)

      # Implement the required interface for Rails::Generators::Migration.
      def self.next_migration_number(dirname)
        next_migration_number = current_migration_number(dirname) + 1
        ActiveRecord::Migration.next_migration_number(next_migration_number)
      end

      desc "Copy all files to your application."
      def generate_files
        migration_template "create_passkit_tables.rb", "db/migrate/create_passkit_tables.rb"
        copy_file "passkit.rb", "config/initializers/passkit.rb"
      end

      # Existing installs upgrading from < 1.0 need the unique index on
      # passkit_passes.serial_number. Copy the template manually:
      #   bundle exec rails generate migration AddUniqueIndexOnPasskitPassesSerialNumber
      # then paste:
      #   add_index :passkit_passes, :serial_number, unique: true
      # See lib/generators/templates/add_unique_index_on_passkit_passes_serial_number.rb.tt
    end
  end
end
