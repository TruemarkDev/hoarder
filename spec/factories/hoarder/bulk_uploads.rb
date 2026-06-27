# frozen_string_literal: true

FactoryBot.define do
  factory :bulk_upload, class: 'Hoarder::BulkUpload' do
    comment { 'test upload' }
    csv { Rack::Test::UploadedFile.new(File.join(ENGINE_ROOT, 'spec', 'support', 'assets', 'valid.csv'), 'text/csv') }
  end
end
