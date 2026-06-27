# frozen_string_literal: true

source 'https://rubygems.org'
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

# Specify your gem's dependencies in hoarder.gemspec.
gemspec

gem 'pg'

gem 'sprockets-rails'

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"

gem 'sidekiq', '~> 7.0'

group :test do
  gem 'simplecov', require: false
end
