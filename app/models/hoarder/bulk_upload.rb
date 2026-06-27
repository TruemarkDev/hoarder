# frozen_string_literal: true

module Hoarder
  class BulkUpload < ApplicationRecord
    enum :status, {
      pending: 'pending',
      uploading: 'uploading',
      uploaded: 'uploaded',
      staging: 'staging',
      staged: 'staged',
      accepted: 'accepted',
      processing: 'processing',
      processed: 'processed',
      failed: 'failed'
    }

    enum :resource_type, Hoarder.resource_types
    belongs_to :uploaded_by, class_name: Hoarder.uploaded_by_class.to_s
    has_one_attached :csv

    validates :uploaded_by_id, presence: true
    validates :csv, presence: true
    validates :resource_type, presence: true
    # Resolved per-validation (lazily) so the message honors the request locale and
    # the engine's own i18n defaults, rather than being frozen at the boot locale.
    validates :csv, length: { maximum: 100.megabytes, message: ->(_object, _data) { I18n.t('hoarder.errors.csv_too_large') } }

    after_create_commit :upload_file_and_update_status

    after_update do
      validation_job.perform_later(id) if saved_change_to_status? && uploaded?
      uploading_job.perform_later(id) if saved_change_to_status? && accepted?
    end

    # Push every status transition to subscribers so the SPA can render progress
    # live instead of polling GET /bulk_uploads/:id/status. Fires only after the
    # transaction commits, so clients never see a status that later rolls back.
    after_update_commit :broadcast_status, if: :saved_change_to_status?

    # Canonical realtime stream name for an upload. The host channel streams from
    # this and the host broadcaster (Hoarder.broadcaster) publishes to it.
    def self.stream_name_for(id)
      "hoarder_bulk_upload_#{id}"
    end

    def stream_name
      self.class.stream_name_for(id)
    end

    def upload_file_and_update_status
      Hoarder::FileUploadJob.perform_later(id)
      # Indicate the file upload is in progress.
      update!(status: 'uploading')
    end

    def trigger_validation_job_if_csv_attached
      validation_job.perform_later(id)
    end

    # Stage (validate) an uploaded file. The host block does the resource-specific
    # validation and writes `data`; the engine owns the transaction, the
    # idempotency guard, and the status/failure transitions. A retried or
    # concurrent job that finds the upload already past `uploaded` is a no-op, and
    # any error rolls back the whole staging step before marking the upload failed.
    def stage
      return false unless claim!(precondition: :uploaded?, transition: :set_as_staging)

      transaction do
        yield(self)
        set_as_staged
      end
      true
    rescue StandardError => e
      record_failure(e)
      false
    end

    # Process (import) a staged-and-accepted file. Same contract as #stage: the
    # host block performs the inserts, the engine wraps them in a transaction with
    # an idempotency guard so a retry can't double-import, and rolls everything
    # back on failure. Best for set-based hosts that import in a single statement
    # (e.g. insert_all); for large per-record imports use #process_in_batches.
    def process
      return false unless claim!(precondition: :accepted?, transition: :set_as_processing)

      transaction do
        yield(self)
        set_as_processed
      end
      true
    rescue StandardError => e
      record_failure(e)
      false
    end

    # Default chunk size for #process_in_batches.
    PROCESS_BATCH_SIZE = 500
    private_constant :PROCESS_BATCH_SIZE

    # Import a large, ordered set of staged records in committed chunks rather than
    # one long-held transaction. Each chunk is imported and the checkpoint
    # (processed_count) advanced in the SAME short transaction under a row lock, so:
    #   * transactions stay small — no DB connection pinned for the whole import,
    #     which matters under PgBouncer transaction pooling;
    #   * a crash mid-import is resumable — a re-run skips the rows already
    #     committed (resume from processed_count) instead of redoing all of them;
    #   * concurrent or retried jobs cooperate safely — the row lock serializes the
    #     checkpoint read-and-advance, so no chunk is imported twice.
    # The block receives each chunk and its absolute offset and performs the
    # inserts; the engine owns the claim, chunking, checkpoint, per-chunk progress
    # broadcast and the terminal transition. `records` must be a stable, ordered,
    # indexable collection (e.g. the staged records array).
    #
    # `after_commit` (optional) is called with (chunk, offset) AFTER each chunk's
    # transaction commits — the place for non-transactional side effects that must
    # not fire if the chunk rolls back (e.g. enqueuing emails for the rows just
    # saved). It does not run for a chunk that raised.
    def process_in_batches(records, batch_size: PROCESS_BATCH_SIZE, after_commit: nil)
      return false unless claim!(precondition: :resumable_for_processing?, transition: :set_as_processing)

      total = records.size
      loop do
        committed = nil
        finished = with_lock do
          offset = processed_count
          if offset >= total
            true
          else
            batch = records[offset, batch_size]
            yield(batch, offset)
            # Checkpoint advance, deliberately without callbacks/validations.
            update_column(:processed_count, offset + batch.size) # rubocop:disable Rails/SkipsModelValidations
            committed = [batch, offset]
            false
          end
        end

        break if finished

        # Runs outside the transaction, so a rolled-back chunk fires nothing.
        after_commit&.call(*committed)
        broadcast_progress([processed_count, total].min, total)
      end

      set_as_processed
      true
    rescue StandardError => e
      record_failure(e)
      false
    end

    def set_as_staging
      update!(
        status: 'staging',
        message: 'Staging uploaded file.'
      )
      save!(validate: false)
    end

    def set_as_staged
      update!(
        status: 'staged',
        message: 'Successfully staged data.'
      )
      save!(validate: false)
    end

    def set_as_accepted
      update!(
        status: 'accepted',
        message: 'Ready for import.'
      )
      save!(validate: false)
    end

    def set_as_processing
      update!(
        status: 'processing',
        message: 'Processing data.'
      )
      save!(validate: false)
    end

    def set_as_processed
      update!(
        status: 'processed',
        message: "Successfully imported #{valid_records.count} records."
      )
      save!(validate: false)
    end

    # Part of the set_as_* status-transition family (not a writer/accessor).
    def set_as_failed(message) # rubocop:disable Naming/AccessorMethodName
      update!(
        status: 'failed',
        message: message
      )
      save!(validate: false)
    end

    # Broadcast incremental progress (e.g. "processed 12 of 40") for hosts whose
    # import does per-record work. No-op unless a broadcaster is configured.
    def broadcast_progress(processed, total)
      broadcast(type: 'progress', status: status, processed: processed, total: total)
    end

    def validation_job
      Hoarder.background_jobs[resource_type.to_sym][0].constantize
    end

    def uploading_job
      Hoarder.background_jobs[resource_type.to_sym][1].constantize
    end

    def valid_records
      data['valid_records'].pluck('record')
    end

    def invalid_records
      data['invalid_records'].pluck('record')
    end

    def duplicate_records
      data['duplicate_records'].pluck('record')
    end

    # True when an import may (re)start: a fresh accepted upload, or one left in
    # `processing` by a crashed/interrupted run that should resume from its
    # checkpoint. Used as the #process_in_batches claim precondition.
    def resumable_for_processing?
      accepted? || processing?
    end

    private

    # Row-lock the upload and transition it only if it is still in the expected
    # start state, so concurrent or retried jobs can't both claim the same upload.
    def claim!(precondition:, transition:)
      with_lock do
        next false unless public_send(precondition)

        public_send(transition)
        true
      end
    end

    def record_failure(error)
      reload
      set_as_failed(
        Rails.env.production? ? error.message : "#{error.message}\n#{error.backtrace.join("\n")}"
      )
    end

    def broadcast_status
      broadcast(type: 'status', status: status, message: message)
    end

    def broadcast(payload)
      Hoarder.broadcaster&.call(stream_name, payload.merge(id: id))
    end
  end
end
