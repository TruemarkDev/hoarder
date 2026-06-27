# frozen_string_literal: true

require 'hoarder/version'
require 'hoarder/engine'

module Hoarder
  # Host-app injected configuration. See the host's config/initializers/hoarder.rb.
  #
  # extra_params values are callables (->(params) { ... }) resolved against the
  # request params at upload time; broadcaster, when set, is a callable
  # ->(stream_name, payload) { ... } the engine uses to push status/progress over
  # the host's realtime transport (e.g. ActionCable).
  mattr_accessor :uploaded_by_class, :resource_types, :background_jobs, :correct_header, :extra_params,
                 :allow_invalid_data, :application_controller, :broadcaster
end
