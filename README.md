# Hoarder

Hoarder is a mountable Rails engine that provides a generic, reusable **bulk CSV
upload pipeline**. It is resource-agnostic: the host application configures *what*
can be uploaded and *how* each resource is validated and imported, while the
engine owns the upload lifecycle — file handling, the status state machine,
transactional/idempotent staging and processing, and realtime progress
broadcasting.

It is currently used in GaugeHire to bulk-upload company locations and job
invitations.

## Installation

Add the gem (distributed from GitHub, not RubyGems):

```ruby
# Gemfile
gem 'hoarder', github: 'TruemarkDev/hoarder', tag: 'v0.1.0'
```

Hoarder stores each upload's CSV with **Active Storage**, so the host app must
have Active Storage installed and migrated:

```bash
bin/rails active_storage:install
```

Copy the engine's migration into the host and run it (this creates the
`hoarder_bulk_uploads` table — Rails generates the `hoarder:install:migrations`
task automatically for the mounted engine):

```bash
bin/rails hoarder:install:migrations
bin/rails db:migrate
```

Mount the engine:

```ruby
# config/routes.rb
mount Hoarder::Engine, at: '/hoarder'
```

Then configure it from an initializer — see [Configuration](#configuration).
Re-run `bin/rails hoarder:install:migrations && bin/rails db:migrate` after
upgrading the gem to pick up any new engine migrations.

## Lifecycle

Every upload is a single `Hoarder::BulkUpload` row with a CSV attached via Active
Storage and a `data` JSON column holding the parsed results
(`valid_records` / `invalid_records` / `duplicate_records`). It moves through:

```
pending → uploading → uploaded → staging → staged → accepted → processing → processed
                                                                              ↘ failed
```

1. **create** — the controller validates the CSV (non-empty, correct headers,
   any required extra params) and creates the upload. On commit a file-upload job
   confirms the Active Storage blob and advances to `uploaded`.
2. **stage** — reaching `uploaded` enqueues the resource's *validation job*, which
   calls `BulkUpload#stage { ... }`. The block does resource-specific validation
   and writes `data`; the engine wraps it in a transaction, guards against
   double-staging, and transitions `staging → staged`.
3. **review** — the client fetches `GET /bulk_uploads/:id` and either polls
   `GET /bulk_uploads/:id/status` or subscribes to the realtime stream (below).
4. **accept + process** — `PATCH /bulk_uploads/:id` marks it `accepted`, enqueuing
   the *uploading job*, which calls `BulkUpload#process { ... }`. The block performs
   the import; the engine wraps it in a transaction with an idempotency guard so a
   retried job can't double-import, transitioning `processing → processed` (or
   `failed`, rolling everything back).

`#stage` and `#process` are the engine's transaction/idempotency boundary — host
jobs are thin adapters that only supply the resource-specific block.

## Configuration

Mount the engine and configure it from the host app
(`config/initializers/hoarder.rb`):

```ruby
mount Hoarder::Engine, at: '/hoarder'
```

```ruby
# Base controller the engine's controller inherits from (auth, current_user, …).
Hoarder.application_controller = '::Api::BaseController'

# Model that owns uploads. It must define `has_many :bulk_uploads`.
Hoarder.uploaded_by_class = 'Companies::User'

# enum mapping of uploadable resource types.
Hoarder.resource_types = {
  'Companies::Location': 'Companies::Location',
  JobInvitation: 'JobInvitation'
}

# Per-resource [ValidationJob, UploadingJob]. Looked up and constantized at runtime.
Hoarder.background_jobs = {
  'Companies::Location': ['BulkUploads::Locations::ValidationJob', 'BulkUploads::Locations::UploadingJob'],
  JobInvitation: ['BulkUploads::JobInvitations::ValidationJob', 'BulkUploads::JobInvitations::UploadingJob']
}

# Expected CSV headers per resource (validated on upload).
Hoarder.correct_header = {
  'Companies::Location': %w[city state country country_code state_code address_line_1 address_line_2 zip_code],
  JobInvitation: ['email']
}

# Extra params some resources need. Each value is a *resolver* — a callable run
# against the request params at upload time that returns the value to persist in
# `data`, or nil to reject the request as invalid (422). (Earlier versions eval'd
# code strings here; resolvers replace that.)
Hoarder.extra_params = {
  JobInvitation: { job_id: ->(params) { ::Companies::Job.find_by(id: params[:job_id])&.id } }
}

# Resources that may import despite invalid rows (when the client opts in).
Hoarder.allow_invalid_data = ['Companies::Location']

# Optional: a callable ->(stream_name, payload) the engine uses to push
# status/progress updates. Wire it to your realtime transport.
Hoarder.broadcaster = ->(stream_name, payload) { ActionCable.server.broadcast(stream_name, payload) }
```

## Realtime progress

When `Hoarder.broadcaster` is set, the engine pushes each status transition (and
optional per-record progress) to a per-upload stream, so the client can render
live progress instead of polling. The canonical stream name is
`Hoarder::BulkUpload.stream_name_for(id)`.

Payloads are `{ type: 'status', status:, message:, id: }` for transitions and
`{ type: 'progress', status:, processed:, total:, id: }` when a host job calls
`bulk_upload.broadcast_progress(processed, total)` during its import loop.

In the host, expose and authorize the stream with a channel — e.g.:

```ruby
class BulkUploadsChannel < ApplicationCable::Channel
  def subscribed
    return reject unless current_user.respond_to?(:bulk_uploads)

    bulk_upload = current_user.bulk_uploads.find_by(id: params[:id])
    return reject unless bulk_upload

    stream_from Hoarder::BulkUpload.stream_name_for(bulk_upload.id)
  end
end
```

To set realtime up end to end:

1. **Have a working Action Cable adapter.** In production use a real backend —
   `solid_cable` (DB-backed, no extra infra) or the `redis` adapter — in
   `config/cable.yml`. The `async` (in-process) adapter is dev/test only and does
   not fan out across processes.
2. **Set `Hoarder.broadcaster`** in the initializer (above). The engine broadcasts
   *only* when it is set; leave it unset to run in polling-only mode.
3. **Add the channel** above so clients can subscribe to a specific upload's stream.
4. **Subscribe from the client** to that channel, keyed by the upload id:

   ```js
   import { createConsumer } from "@rails/actioncable"

   createConsumer().subscriptions.create(
     { channel: "BulkUploadsChannel", id: bulkUploadId },
     { received: (data) => {
         // { type: 'status', status, message, id }
         // { type: 'progress', status, processed, total, id }
       } }
   )
   ```

`GET /bulk_uploads/:id/status` remains available as a polling fallback when
realtime is not configured.

## Writing a resource

For a new resource, add it to the four config maps above and provide two jobs.
The jobs only supply the resource-specific work inside the engine's
`#stage` / `#process` blocks:

```ruby
module BulkUploads
  module Widgets
    class ValidationJob < ::ApplicationJob
      def perform(bulk_upload_id)
        bulk_upload = ::Hoarder::BulkUpload.find(bulk_upload_id)
        bulk_upload.stage do
          # parse bulk_upload.csv, classify rows, and write bulk_upload.data
        end
      end
    end

    class UploadingJob < ::ApplicationJob
      def perform(bulk_upload_id)
        bulk_upload = ::Hoarder::BulkUpload.find(bulk_upload_id)
        bulk_upload.process do
          # import bulk_upload.valid_records (optionally broadcast_progress)
        end
      end
    end
  end
end
```

## Development & tests

The engine ships a dummy host app under `spec/dumm` and is fully spec'd
(100% line + branch coverage, enforced via SimpleCov).

```bash
cd engines/hoarder
bundle install
cd spec/dumm && RAILS_ENV=test bundle exec rails db:create db:schema:load && cd -
RAILS_ENV=test bundle exec rspec     # coverage report written to coverage/
```

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
