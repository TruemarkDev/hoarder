# frozen_string_literal: true

require_relative 'lib/hoarder/version'

Gem::Specification.new do |spec|
  spec.name        = 'hoarder'
  spec.version     = Hoarder::VERSION
  spec.authors     = ['Prakash Poudel Sharma']
  spec.email       = ['prakash@truemark.com.np']
  spec.homepage    = 'https://github.com/TruemarkDev/hoarder'
  spec.summary     = 'Resource-agnostic bulk CSV upload pipeline for Rails'
  spec.description = 'A mountable Rails engine that owns the bulk-upload lifecycle — ' \
                    'file handling, a status state machine, transactional/idempotent ' \
                    'staging and processing, and realtime progress broadcasting — while ' \
                    'the host app configures what can be uploaded and how each resource ' \
                    'is validated and imported.'
  spec.license     = 'MIT'
  spec.required_ruby_version = '>= 3.4'

  # Not yet published to a registry. This blocks an accidental `gem push` to
  # RubyGems.org; set it to your gem host (or delete the line) when you publish.
  spec.metadata['allowed_push_host'] = 'https://rubygems.pkg.github.com/TruemarkDev'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir['{app,config,db,lib}/**/*', 'MIT-LICENSE', 'CHANGELOG.md', 'Rakefile', 'README.md']
  end

  spec.add_development_dependency('factory_bot_rails')
  spec.add_development_dependency('pry-rails', '~> 0.3.9')
  spec.add_dependency('csv')
  spec.add_dependency('rails', '>= 7.0.4')
  spec.add_development_dependency('rspec-rails')
  spec.metadata['rubygems_mfa_required'] = 'true'
end
