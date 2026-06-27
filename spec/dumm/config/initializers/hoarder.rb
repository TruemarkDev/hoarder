Hoarder.application_controller = '::ApplicationController'
Hoarder.resource_types = {
  GenericResource: 'GenericResource',
  RestrictedResource: 'RestrictedResource'
}

Hoarder.uploaded_by_class = 'User'

Hoarder.background_jobs = {
  GenericResource: ['GenericResources::ValidationJob', 'GenericResources::UploadingJob'],
  RestrictedResource: ['GenericResources::ValidationJob', 'GenericResources::UploadingJob']
}

Hoarder.correct_header = {
  GenericResource: %w[name message],
  RestrictedResource: %w[name message]
}

# RestrictedResource exercises the extra-params resolver path (a token must be
# present and resolve to a truthy value); GenericResource has none.
Hoarder.extra_params = {
  RestrictedResource: { token: ->(params) { params[:token].presence } }
}

Hoarder.allow_invalid_data = ['GenericResource']

# Hoarder.broadcaster is wired to ActionCable in the real host app; specs set it
# to an in-memory sink to assert status/progress broadcasts.
