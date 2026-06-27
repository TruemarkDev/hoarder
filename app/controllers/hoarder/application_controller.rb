# frozen_string_literal: true

module Hoarder
  class ApplicationController < Hoarder.application_controller.constantize
    before_action :require_authenticated_uploader

    private

    # All Hoarder actions are scoped to `current_user.bulk_uploads`, so they
    # require an authenticated user. Without this guard an unauthenticated request
    # reaches the action with a nil current_user and 500s on `current_user…`;
    # here it gets a clean 401 regardless of the host's auth mechanism.
    def require_authenticated_uploader
      return if current_user

      render(json: { message: I18n.t('hoarder.errors.unauthorized') }, status: :unauthorized)
    end
  end
end
