class ApplicationController < ActionController::Base
  require 'csv'
  def current_user
    User.last
  end
end
