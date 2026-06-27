# frozen_string_literal: true

module Hoarder
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
