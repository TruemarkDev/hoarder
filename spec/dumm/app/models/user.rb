class User < ApplicationRecord
  has_many :bulk_uploads, class_name: 'Hoarder::BulkUpload', foreign_key: 'uploaded_by_id'
end
