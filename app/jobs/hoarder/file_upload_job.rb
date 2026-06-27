# frozen_string_literal: true

module Hoarder
  # Confirms the CSV is attached and analyzed by Active Storage, then advances the
  # upload to `uploaded` (which triggers the resource's validation job). If the
  # blob isn't analyzed yet, it re-enqueues itself via #upload_file_and_update_status.
  class FileUploadJob < ApplicationJob
    queue_as :default

    def perform(bulk_upload_id)
      bulk_upload = BulkUpload.find(bulk_upload_id)
      file = bulk_upload.csv

      if file.attached? && file.metadata['analyzed'].present?
        bulk_upload.update!(status: 'uploaded', message: 'Successfully uploaded!')
      else
        bulk_upload.upload_file_and_update_status
      end
    end
  end
end
