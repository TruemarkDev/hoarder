# frozen_string_literal: true

require 'rails_helper'

RSpec.describe(Hoarder::FileUploadJob, type: :job) do
  let(:user) { create(:user) }
  let(:bulk_upload) { create(:bulk_upload, resource_type: 'GenericResource', uploaded_by: user) }

  it 'marks the upload as uploaded once the blob is analyzed' do
    bulk_upload.csv.blob.update!(metadata: bulk_upload.csv.blob.metadata.merge('analyzed' => true))

    described_class.perform_now(bulk_upload.id)

    expect(bulk_upload.reload.status).to(eq('uploaded'))
    expect(bulk_upload.message).to(eq('Successfully uploaded!'))
  end

  it 're-triggers the upload flow when the blob is not yet analyzed' do
    bulk_upload.csv.blob.update!(metadata: bulk_upload.csv.blob.metadata.except('analyzed'))

    expect_any_instance_of(Hoarder::BulkUpload).to(receive(:upload_file_and_update_status))

    described_class.perform_now(bulk_upload.id)
  end
end
