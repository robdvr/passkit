class AddUniqueIndexesOnPasskitDevicesAndRegistrations < ActiveRecord::Migration[8.1]
  def change
    add_index :passkit_devices, :identifier, unique: true
    add_index :passkit_registrations, [:passkit_pass_id, :passkit_device_id], unique: true,
      name: "index_passkit_registrations_on_pass_and_device"
  end
end
