# frozen_string_literal: true

require 'rails_helper'

RSpec.describe(Hoarder::BulkUpload, type: :model) do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }
  let(:bulk_upload) { build(:bulk_upload, resource_type: 'GenericResource', uploaded_by: user) }

  # Capture engine broadcasts in-memory so we can assert status/progress pushes.
  let(:broadcasts) { [] }

  before { Hoarder.broadcaster = -> (stream, payload) { broadcasts << { stream: stream, payload: payload } } }
  after { Hoarder.broadcaster = nil }

  # Persist an upload sitting in a known status without firing lifecycle callbacks.
  def upload_in(status)
    upload = create(:bulk_upload, resource_type: 'GenericResource', uploaded_by: user)
    upload.update_column(:status, status)
    broadcasts.clear
    upload.reload
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(bulk_upload).to(be_valid)
    end

    it 'is not valid without a resource type' do
      bulk_upload.resource_type = nil
      expect(bulk_upload).not_to(be_valid)
    end

    it 'is not valid without a uploaded_by' do
      bulk_upload.uploaded_by = nil
      expect(bulk_upload).not_to(be_valid)
    end

    it 'is not valid without a csv' do
      bulk_upload.csv = nil
      expect(bulk_upload).not_to(be_valid)
    end
  end

  describe 'stream names' do
    it 'derives a deterministic stream name from the id' do
      expect(described_class.stream_name_for(42)).to(eq('hoarder_bulk_upload_42'))
    end

    it 'exposes the instance stream name' do
      bulk_upload.save!
      expect(bulk_upload.stream_name).to(eq("hoarder_bulk_upload_#{bulk_upload.id}"))
    end
  end

  describe 'creation lifecycle' do
    it 'enqueues the file upload job and moves to uploading' do
      expect do
        bulk_upload.save!
      end.to(have_enqueued_job(Hoarder::FileUploadJob))
      expect(bulk_upload.reload.status).to(eq('uploading'))
    end

    it 'broadcasts the status change on commit' do
      bulk_upload.save!
      expect(broadcasts.map { |b| b[:payload][:status] }).to(include('uploading'))
      expect(broadcasts.last[:stream]).to(eq(bulk_upload.stream_name))
    end
  end

  describe 'job wiring' do
    it 'enqueues the validation job when an upload becomes uploaded' do
      upload = upload_in('uploading')
      expect do
        upload.update!(status: 'uploaded')
      end.to(have_enqueued_job(GenericResources::ValidationJob).with(upload.id))
    end

    it 'enqueues the uploading job when an upload is accepted' do
      upload = upload_in('staged')
      expect do
        upload.set_as_accepted
      end.to(have_enqueued_job(GenericResources::UploadingJob).with(upload.id))
    end

    it 'resolves the configured validation and uploading jobs' do
      bulk_upload.save!
      expect(bulk_upload.validation_job).to(eq(GenericResources::ValidationJob))
      expect(bulk_upload.uploading_job).to(eq(GenericResources::UploadingJob))
    end

    it 'can trigger the validation job directly' do
      bulk_upload.save!
      expect do
        bulk_upload.trigger_validation_job_if_csv_attached
      end.to(have_enqueued_job(GenericResources::ValidationJob).with(bulk_upload.id))
    end
  end

  describe '#stage' do
    it 'runs the block and advances to staged' do
      upload = upload_in('uploaded')
      result = upload.stage { |u| u.update!(data: { 'valid_records' => [] }) }

      expect(result).to(be(true))
      expect(upload.reload.status).to(eq('staged'))
    end

    it 'is a no-op unless the upload is in the uploaded state (idempotency)' do
      upload = upload_in('staged')
      ran = false
      result = upload.stage { ran = true }

      expect(result).to(be(false))
      expect(ran).to(be(false))
      expect(upload.reload.status).to(eq('staged'))
    end

    it 'rolls back and fails the upload when the block raises' do
      upload = upload_in('uploaded')
      result = upload.stage { raise('boom while staging') }

      expect(result).to(be(false))
      expect(upload.reload.status).to(eq('failed'))
      expect(upload.message).to(include('boom while staging'))
      expect(broadcasts.map { |b| b[:payload][:status] }).to(include('failed'))
    end
  end

  describe '#process' do
    def accepted_upload
      upload = upload_in('accepted')
      upload.update_column(:data, { 'valid_records' => [{ 'record' => { 'name' => 'a', 'message' => 'b' } }] })
      upload.reload
    end

    it 'runs the block atomically and advances to processed' do
      upload = accepted_upload
      result = upload.process { |u| GenericResource.create!(name: u.valid_records.first['name']) }

      expect(result).to(be(true))
      expect(upload.reload.status).to(eq('processed'))
      expect(GenericResource.count).to(eq(1))
    end

    it 'does not re-process an upload that is not accepted (idempotency)' do
      upload = upload_in('processed')
      ran = false
      result = upload.process { ran = true }

      expect(result).to(be(false))
      expect(ran).to(be(false))
    end

    it 'rolls back inserts and fails the upload when the block raises' do
      upload = accepted_upload
      result = upload.process do
        GenericResource.create!(name: 'created then rolled back')
        raise('boom while processing')
      end

      expect(result).to(be(false))
      expect(upload.reload.status).to(eq('failed'))
      expect(GenericResource.count).to(eq(0))
    end
  end

  describe '#process_in_batches' do
    # A staged upload with `count` valid records, each a { 'name' => ... } hash.
    def accepted_upload_with(count)
      upload = upload_in('accepted')
      records = Array.new(count) { |i| { 'record' => { 'name' => "r#{i}" } } }
      upload.update_column(:data, { 'valid_records' => records })
      upload.reload
    end

    def import!(upload, **, &)
      upload.process_in_batches(upload.data['valid_records'].pluck('record'), **, &)
    end

    it 'imports every record in chunks and advances to processed' do
      upload = accepted_upload_with(5)
      result = import!(upload, batch_size: 2) do |batch, _offset|
        batch.each { |record| GenericResource.create!(name: record['name']) }
      end

      expect(result).to(be(true))
      expect(upload.reload.status).to(eq('processed'))
      expect(GenericResource.count).to(eq(5))
      expect(upload.processed_count).to(eq(5))
    end

    it 'commits each chunk in its own transaction (checkpoint advances per chunk)' do
      upload = accepted_upload_with(5)
      seen = []
      import!(upload, batch_size: 2) do |batch, offset|
        batch.each { |record| GenericResource.create!(name: record['name']) }
        seen << [offset, upload.reload.processed_count]
      end

      # processed_count is read at the START of each chunk, so offsets walk 0,2,4.
      expect(seen.map(&:first)).to(eq([0, 2, 4]))
    end

    it 'broadcasts progress after each committed chunk' do
      upload = accepted_upload_with(5)
      import!(upload, batch_size: 2) { |batch, _o| batch.each { GenericResource.create!(name: 'x') } }

      progress = broadcasts.map { |b| b[:payload] }.select { |p| p[:type] == 'progress' }
      expect(progress.pluck(:processed)).to(eq([2, 4, 5]))
      expect(progress.last).to(include(total: 5))
    end

    it 'resumes from the checkpoint instead of re-importing committed rows' do
      upload = accepted_upload_with(5)
      # Simulate a crash after the first chunk: commit two rows, then bail without
      # the rescue running (status stays `processing`, checkpoint at 2).
      upload.update_columns(status: 'processing', processed_count: 2)
      GenericResource.create!(name: 'r0')
      GenericResource.create!(name: 'r1')

      imported = []
      result = import!(upload.reload, batch_size: 2) do |batch, _offset|
        batch.each do |record|
          imported << record['name']
          GenericResource.create!(name: record['name'])
        end
      end

      expect(result).to(be(true))
      # Only the un-committed tail is re-imported, not the checkpointed rows.
      expect(imported).to(eq(%w[r2 r3 r4]))
      expect(GenericResource.count).to(eq(5))
      expect(upload.reload.status).to(eq('processed'))
    end

    it 'does not start for an upload that is neither accepted nor processing (idempotency)' do
      upload = upload_in('processed')
      ran = false
      result = upload.process_in_batches([1, 2, 3]) { ran = true }

      expect(result).to(be(false))
      expect(ran).to(be(false))
    end

    it 'rolls back the failing chunk and fails the upload when the block raises' do
      upload = accepted_upload_with(5)
      result = import!(upload, batch_size: 2) do |batch, offset|
        raise('boom on second chunk') if offset == 2

        batch.each { |record| GenericResource.create!(name: record['name']) }
      end

      expect(result).to(be(false))
      expect(upload.reload.status).to(eq('failed'))
      # First chunk committed (2), the raising chunk rolled back — no partial chunk.
      expect(GenericResource.count).to(eq(2))
      expect(upload.processed_count).to(eq(2))
    end

    it 'handles an empty record set' do
      upload = accepted_upload_with(0)
      ran = false
      result = import!(upload) { ran = true }

      expect(result).to(be(true))
      expect(ran).to(be(false))
      expect(upload.reload.status).to(eq('processed'))
    end

    it 'runs the after_commit hook once per committed chunk, with the chunk + offset' do
      upload = accepted_upload_with(5)
      committed = []
      import!(upload, batch_size: 2, after_commit: -> (chunk, offset) { committed << [offset, chunk.size] }) do |batch, _o|
        batch.each { |record| GenericResource.create!(name: record['name']) }
      end

      expect(committed).to(eq([[0, 2], [2, 2], [4, 1]]))
    end

    it 'does not run the after_commit hook for a chunk that rolled back' do
      upload = accepted_upload_with(5)
      hooked = []
      import!(upload, batch_size: 2, after_commit: -> (_chunk, offset) { hooked << offset }) do |batch, offset|
        raise(StandardError, 'boom on second chunk') if offset == 2

        batch.each { |record| GenericResource.create!(name: record['name']) }
      end

      # Only the first chunk committed, so only it fired the post-commit hook —
      # the rolled-back chunk's side effects (e.g. emails) never run.
      expect(hooked).to(eq([0]))
    end
  end

  describe 'status transition helpers' do
    it 'transitions through each state with a message' do
      upload = upload_in('uploaded')

      upload.set_as_staging
      expect(upload.status).to(eq('staging'))
      upload.set_as_staged
      expect(upload.status).to(eq('staged'))
      upload.set_as_accepted
      expect(upload.status).to(eq('accepted'))
      upload.set_as_processing
      expect(upload.status).to(eq('processing'))

      upload.update_column(:data, { 'valid_records' => [{ 'record' => {} }, { 'record' => {} }] })
      upload.reload.set_as_processed
      expect(upload.status).to(eq('processed'))
      expect(upload.message).to(eq('Successfully imported 2 records.'))

      upload.set_as_failed('it broke')
      expect(upload.status).to(eq('failed'))
      expect(upload.message).to(eq('it broke'))
    end
  end

  describe 'record accessors' do
    let(:data) do
      {
        'valid_records' => [{ 'record' => 'v1' }],
        'invalid_records' => [{ 'record' => 'i1' }],
        'duplicate_records' => [{ 'record' => 'd1' }]
      }
    end

    before do
      bulk_upload.save!
      bulk_upload.update_column(:data, data)
      bulk_upload.reload
    end

    it 'plucks valid, invalid and duplicate records' do
      expect(bulk_upload.valid_records).to(eq(['v1']))
      expect(bulk_upload.invalid_records).to(eq(['i1']))
      expect(bulk_upload.duplicate_records).to(eq(['d1']))
    end
  end

  describe '#broadcast_progress' do
    it 'broadcasts a progress payload to the upload stream' do
      bulk_upload.save!
      broadcasts.clear
      bulk_upload.broadcast_progress(3, 10)

      expect(broadcasts.last[:stream]).to(eq(bulk_upload.stream_name))
      expect(broadcasts.last[:payload]).to(include(type: 'progress', processed: 3, total: 10, id: bulk_upload.id))
    end

    it 'is a no-op when no broadcaster is configured' do
      bulk_upload.save!
      Hoarder.broadcaster = nil
      expect { bulk_upload.broadcast_progress(1, 1) }.not_to(raise_error)
    end
  end

  describe 'failure messaging' do
    it 'includes the backtrace outside production' do
      upload = upload_in('uploaded')
      upload.stage { raise('detailed failure') }
      expect(upload.reload.message).to(include('detailed failure'))
      expect(upload.message.lines.size).to(be > 1)
    end

    it 'reports only the message in production' do
      allow(Rails).to(receive(:env).and_return(ActiveSupport::StringInquirer.new('production')))
      upload = upload_in('uploaded')
      upload.stage { raise('prod failure') }
      expect(upload.reload.message).to(eq('prod failure'))
    end
  end
end
