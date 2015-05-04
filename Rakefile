require 'bundler'
require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'

task default: [:style, :spec]

desc 'Run rubocop'
RuboCop::RakeTask.new(:style)

desc 'Run specs'
RSpec::Core::RakeTask.new(:spec) do |spec|
  spec.pattern = 'spec/**/*_spec.rb'
  # TODO: add back integration tests whenever we have strategy for keys
  spec.exclude_pattern = 'spec/integration/**/*_spec.rb'
end
