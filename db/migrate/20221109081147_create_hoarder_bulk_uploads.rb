class CreateHoarderBulkUploads < ActiveRecord::Migration[7.0]
  def change
    create_table :hoarder_bulk_uploads do |t|
      t.string :status, null: false, default: 'pending'
      t.string :comment
      t.string :message

      t.timestamps
    end
  end
end
