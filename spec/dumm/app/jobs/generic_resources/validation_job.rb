module GenericResources
  class ValidationJob < ApplicationJob
    def perform(bulk_upload_id)
      bulk_upload = Hoarder::BulkUpload.find(bulk_upload_id)

      bulk_upload.stage do
        rows = CSV.parse(bulk_upload.csv.download, headers: true)
        valid_records = rows.map { |row| { 'record' => row.to_h } }
        bulk_upload.update!(
          data: (bulk_upload.data || {}).merge(
            'valid_records' => valid_records,
            'invalid_records' => [],
            'duplicate_records' => []
          )
        )
      end
    end
  end
end
