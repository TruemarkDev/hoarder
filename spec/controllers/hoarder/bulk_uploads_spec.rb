# frozen_string_literal: true

require 'rails_helper'

RSpec.describe('Hoarder::BulkUploads', type: :request) do
  let!(:user) { create(:user) }
  let(:bulk_upload) { build(:bulk_upload, resource_type: 'GenericResource', uploaded_by: user) }
  let(:valid_csv) { upload_file('valid.csv') }
  let(:invalid_csv) { upload_file('invalid.csv') }
  let(:empty_csv) { upload_file('empty.csv') }

  def upload_file(name)
    Rack::Test::UploadedFile.new(File.join(ENGINE_ROOT, 'spec', 'support', 'assets', name), 'text/csv')
  end

  before { @routes = Hoarder::Engine.routes }

  describe 'authentication' do
    it 'responds 401 when there is no current user' do
      allow_any_instance_of(Hoarder::ApplicationController).to(receive(:current_user).and_return(nil))
      get(bulk_upload_url(123))
      expect(response).to(have_http_status(:unauthorized))
    end
  end

  describe 'GET /show' do
    it 'renders a successful response' do
      bulk_upload.save!
      get(bulk_upload_url(bulk_upload))
      expect(response).to(be_successful)
    end

    it 'shows the correct bulk_upload' do
      bulk_upload.save!
      get(bulk_upload_url(bulk_upload))
      expect(JSON.parse(response.body)['id']).to(eq(bulk_upload.id))
    end
  end

  describe 'GET /status' do
    it 'returns the status and message' do
      bulk_upload.save!
      get(status_bulk_upload_url(bulk_upload))
      json = JSON.parse(response.body)
      expect(response).to(have_http_status(:ok))
      expect(json).to(include('status', 'message'))
    end
  end

  describe 'POST /create' do
    it 'creates a new bulk upload' do
      expect do
        post(bulk_uploads_url, params: { bulk_upload: { csv: valid_csv, resource_type: 'GenericResource' } })
      end.to(change(Hoarder::BulkUpload, :count).by(1))
    end

    it 'enqueues the file upload job' do
      expect do
        post(bulk_uploads_url, params: { bulk_upload: { csv: valid_csv, resource_type: 'GenericResource' } })
      end.to(have_enqueued_job(Hoarder::FileUploadJob))
    end

    it 'rejects a request without a resource type' do
      post(bulk_uploads_url, params: { bulk_upload: { csv: valid_csv } })
      expect(response).to(have_http_status(:unprocessable_content))
      expect(JSON.parse(response.body)['error']).to(eq('You should provide resource type'))
    end

    it 'rejects a CSV with no records' do
      post(bulk_uploads_url, params: { bulk_upload: { csv: empty_csv, resource_type: 'GenericResource' } })
      expect(response).to(have_http_status(:unprocessable_content))
      expect(JSON.parse(response.body)['error']).to(match(/no records/i))
    end

    it 'rejects an incorrect header' do
      post(bulk_uploads_url, params: { bulk_upload: { csv: invalid_csv, resource_type: 'GenericResource' } })
      expect(response).to(have_http_status(:unprocessable_content))
      expect(JSON.parse(response.body)['error']).to(eq('Incorrect header'))
    end

    it 'renders model errors when the record cannot be saved' do
      allow_any_instance_of(Hoarder::BulkUpload).to(receive(:save).and_return(false))
      post(bulk_uploads_url, params: { bulk_upload: { csv: valid_csv, resource_type: 'GenericResource' } })
      expect(response).to(have_http_status(:unprocessable_content))
    end

    context 'with a resource that requires extra params' do
      it 'resolves and persists the extra params when valid' do
        post(bulk_uploads_url, params: {
          bulk_upload: { csv: valid_csv, resource_type: 'RestrictedResource' },
          token: 'secret-token'
        }
        )
        expect(response).to(be_successful)
        created = Hoarder::BulkUpload.last
        expect(created.data).to(eq('token' => 'secret-token'))
      end

      it 'rejects the request when a required extra param is missing' do
        post(bulk_uploads_url, params: { bulk_upload: { csv: valid_csv, resource_type: 'RestrictedResource' } })
        expect(response).to(have_http_status(:unprocessable_content))
        expect(JSON.parse(response.body)['error']).to(eq('Something wrong with your query_params'))
      end

      it 'rejects the request when a required extra param resolves to blank' do
        post(bulk_uploads_url, params: {
          bulk_upload: { csv: valid_csv, resource_type: 'RestrictedResource' },
          token: ''
        }
        )
        expect(response).to(have_http_status(:unprocessable_content))
      end
    end
  end

  describe 'PATCH /update' do
    it 'accepts the bulk upload' do
      bulk_upload.save!
      patch(bulk_upload_url(bulk_upload))
      expect(bulk_upload.reload.status).to(eq('accepted'))
    end

    it 'enqueues the uploading job' do
      bulk_upload.save!
      expect do
        patch(bulk_upload_url(bulk_upload))
      end.to(have_enqueued_job(GenericResources::UploadingJob))
    end

    it 'flags allow_invalid_data when permitted and requested' do
      bulk_upload.save!
      bulk_upload.update_column(:data, {})
      patch(bulk_upload_url(bulk_upload), params: { allow_invalid_data: 'true' })
      expect(bulk_upload.reload.data['allow_invalid_data']).to(be(true))
    end

    it 'renders errors when the upload cannot be accepted' do
      bulk_upload.save!
      allow_any_instance_of(Hoarder::BulkUpload).to(receive(:set_as_accepted).and_return(false))
      patch(bulk_upload_url(bulk_upload))
      expect(response).to(have_http_status(:unprocessable_content))
    end
  end

  describe 'DELETE /destroy' do
    it 'destroys the requested bulk upload' do
      bulk_upload.save!
      expect do
        delete(bulk_upload_url(bulk_upload))
      end.to(change(Hoarder::BulkUpload, :count).by(-1))
    end
  end
end
