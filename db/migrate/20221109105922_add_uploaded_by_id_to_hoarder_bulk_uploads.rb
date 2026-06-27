class AddUploadedByIdToHoarderBulkUploads < ActiveRecord::Migration[7.0]
  def self.up
    add_column :hoarder_bulk_uploads, :uploaded_by_id, :integer, null: false
  end

  def self.down
    remove_column :hoarder_bulk_uploads, :uploaded_by_id, :integer
  end
end
