# frozen_string_literal: true

module Hoarder
  class BulkUploadsController < ApplicationController
    def show
      @bulk_upload = current_user.bulk_uploads.find(params[:id])
      render(json: @bulk_upload)
    end

    def status
      @bulk_upload = current_user.bulk_uploads.find(params[:id])
      render(json: { status: @bulk_upload.status, message: @bulk_upload.message }, status: :ok)
    end

    # Validation-heavy action (resource type, extra params, CSV presence/header)
    # — pre-existing complexity, kept as a single guard sequence for readability.
    def create # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      resource_type = bulk_upload_params[:resource_type]
      unless resource_type
        render(json: { error: I18n.t('engine.hoarder.resource_type') },
               status: :unprocessable_content
              ) and return
      end

      if extra_params?(resource_type) # rubocop:disable Style/MissingElse
        unless correct_params?(params, resource_type)
          render(json: { error: I18n.t('engine.hoarder.invalid_query_params') },
                 status: :unprocessable_content
                ) and return

        end

        extra_params = resolve_extra_params(params, resource_type)
      end

      csv_obj = CSV.foreach(bulk_upload_params[:csv])
      unless csv_obj.count > 1
        render(json: { error: I18n.t('hoarder.errors.no_records') },
               status: :unprocessable_content
              ) and return
      end

      headers = csv_obj.first
      unless correct_header?(headers, bulk_upload_params[:resource_type])
        render(json: { error: I18n.t('engine.hoarder.incorrect_header') },
               status: :unprocessable_content
              ) and return
      end

      # NOTE: We need to store 'data' while creating BulkUpload as validation_job triggers at 'after_create'
      @bulk_upload = BulkUpload.new(bulk_upload_params.merge(uploaded_by_id: current_user.id).tap do |params|
        params[:data] = extra_params if extra_params.present?
      end
                                   )
      if @bulk_upload.save
        # TODO: Remove this code changes if the above changes works and not break any other flow
        # @bulk_upload.update!(data: extra_params) if extra_params.present?
        render(json: @bulk_upload)
      else
        render(json: @bulk_upload.errors.details, status: :unprocessable_content)
      end
    end

    def update
      @bulk_upload = current_user.bulk_uploads.find(params[:id])
      if @bulk_upload.set_as_accepted
        allow_invalid_data(@bulk_upload) if Hoarder.allow_invalid_data.include?(@bulk_upload.resource_type) && params[:allow_invalid_data] == 'true'
        render(json: @bulk_upload)
      else
        render(json: @bulk_upload.errors.details, status: :unprocessable_content)
      end
    end

    def destroy
      @bulk_upload = current_user.bulk_uploads.find(params[:id])
      @bulk_upload.destroy!
    end

    private

    def bulk_upload_params
      params.require(:bulk_upload).permit(:csv, :comment, :resource_type)
    end

    def correct_header?(headers, resource_type)
      (headers - Hoarder.correct_header[resource_type.to_sym]).empty?
    end

    def extra_params?(resource_type)
      Hoarder.extra_params.key?(resource_type.to_sym)
    end

    # Each configured extra param is a resolver (->(params) { ... }); the request
    # is valid only if every expected key is present and resolves to a truthy value.
    def correct_params?(params, resource_type)
      Hoarder.extra_params[resource_type.to_sym].all? do |key, resolver|
        params.key?(key) && resolver.call(params)
      end
    end

    # Run each resolver against the request params to build the data we persist.
    def resolve_extra_params(params, resource_type)
      Hoarder.extra_params[resource_type.to_sym].transform_values { |resolver| resolver.call(params) }
    end

    def allow_invalid_data(bulk_upload)
      bulk_upload_data = bulk_upload.data
      bulk_upload_data['allow_invalid_data'] = true
      bulk_upload.update!(data: bulk_upload_data)
    end
  end
end
