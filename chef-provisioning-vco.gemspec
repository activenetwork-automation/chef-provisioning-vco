# coding: utf-8

# rubocop:disable all

lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'chef/provisioning/vco_driver/version'

Gem::Specification.new do |spec|
  spec.name          = 'chef-provisioning-vco'
  spec.version       = Chef::Provisioning::VcoDriver::VERSION
  spec.authors       = ['Gregory Ruiz-Ade']
  spec.email         = ['gkra@unnerving.org']

  # if spec.respond_to?(:metadata)
  #   spec.metadata['allowed_push_host'] = "TODO: Set to 'http://mygemserver.com' to prevent pushes to rubygems.org, or delete to allow pushes to any server."
  # end

  spec.summary       = 'Chef Provisioning Driver for VMware vCAC/vCO IaaS via vcoworkflows'
  spec.description   = 'Chef Provisioning Driver for VMWare vCAC/vCO IaaS via vcoworkflows'
  spec.homepage      = 'https://github.com/vaquero-io/chef-provisioning-vco.git'
  spec.license       = 'apache2'

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'chef-provisioning'
  spec.add_dependency 'vcoworkflows'

  spec.add_development_dependency 'rspec'
  spec.add_development_dependency 'bundler', '~> 1.8'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'guard'
  spec.add_development_dependency 'guard-rubocop'
  spec.add_development_dependency 'guard-rspec'
  spec.add_development_dependency 'guard-yard'
end

# rubocop:enable all
