Rails.application.routes.draw do
  mount Hoarder::Engine, at: '/hoarder'
end
