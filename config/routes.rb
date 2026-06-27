# frozen_string_literal: true

Hoarder::Engine.routes.draw do
  resources :bulk_uploads do
    member do
      get :status
    end
  end
end
