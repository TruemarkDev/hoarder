module GenericResources
  class UploadingJob < ApplicationJob
    def perform(bulk_upload_id)
      bulk_upload = Hoarder::BulkUpload.find(bulk_upload_id)

      bulk_upload.process do
        records = bulk_upload.valid_records
        records.each_with_index do |record, index|
          GenericResource.create!(name: record['name'], message: record['message'])
          bulk_upload.broadcast_progress(index + 1, records.size)
        end
      end
    end
  end
end
