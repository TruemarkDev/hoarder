class AddProcessedCountToHoarderBulkUploads < ActiveRecord::Migration[8.1]
  def change
    # Checkpoint for chunked/resumable imports: how many staged records have been
    # committed so far. A retried job resumes from here instead of re-importing
    # everything. Unused by set-based hosts that import in a single statement.
    add_column(:hoarder_bulk_uploads, :processed_count, :integer, default: 0, null: false)
  end
end
