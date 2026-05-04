class AddUniqueIndexOnPasskitPassesSerialNumber < ActiveRecord::Migration[8.1]
  def change
    add_index :passkit_passes, :serial_number, unique: true
  end
end
