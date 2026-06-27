class AddResourceTypeToHoarderBulkUpload < ActiveRecord::Migration[7.0]
  def self.up
    add_column :hoarder_bulk_uploads, :resource_type, :string, null: false
  end

  def self.down
    remove_column :hoarder_bulk_uploads, :resource_type, :string
  end
end
