# frozen_string_literal: true

require 'rspec/core/rake_task'

begin
  require 'rake/extensiontask'

  # rake-compiler convention: ext/<gem>/extconf.rb -> lib/<gem>/<gem>.bundle
  # Our extconf.rb calls create_makefile('hyperion_http/hyperion_http'), which
  # already lays down the .bundle/.so under hyperion_http/, so we point lib_dir
  # at lib/hyperion_http and rake-compiler will copy the artifact in place.
  Rake::ExtensionTask.new('hyperion_http') do |ext|
    ext.lib_dir = 'lib/hyperion_http'
    ext.ext_dir = 'ext/hyperion_http'
  end

  # Re-compile before running specs so a fresh checkout doesn't need a manual
  # build step. `bundle install && bundle exec rspec` is the documented path.
  task spec: :compile
rescue LoadError
  # rake-compiler not installed (e.g. running from a packaged gem where the
  # extension was already built at install time). Skip the compile hook.
end

RSpec::Core::RakeTask.new(:spec)

namespace :bench do
  desc 'Phase 11 — print per-request allocation count for the request hot path'
  task :yjit_alloc do
    ruby '-Ilib', 'bench/yjit_alloc_audit.rb'
  end
end

task default: :spec
