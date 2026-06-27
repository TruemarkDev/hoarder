class AddDataToHoarderBulkUploads < ActiveRecord::Migration[7.0]
  def self.up
    add_column :hoarder_bulk_uploads, :data, :jsonb
  end

  def self.down
    remove_column :hoarder_bulk_uploads, :data, :jsonb
  end
end
