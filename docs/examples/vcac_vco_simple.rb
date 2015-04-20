# Build a single machine using chef provisioning with vco driver

require 'chef/provisioning/vco_driver'

# Some variables that control where and what we are building
on_behalf_of            = 'svc.vco@example.com'
vcac_tenant             = 'vcac_tenant'
business_unit           = 'ref2'
reservation_policy      = 'nonprod'
site                    = 'uswest'
target_chef_environment = 'dev1'
component               = 'webserver'
instance_id             = '03'
cpu_count               = 2
ram_mb                  = 2048
vm_template             = 'centos-6.6-x86_64-20150325-1'

# Construct the node name
node_name = "#{target_chef_environment}-#{component}-#{instance_id}"

# Configure the driver
with_driver "vco:#{vcac_tenant}:#{business_unit}", :vco_options => {
  url:           'https://vcoserver.example.com:8281/',
  verify_ssl:    false,
  username:      'joeuser',
  password:      'passwords_suck',
  max_wait:      900,
  wait_interval: 15
}

# Build the machine
machine node_name do
  # Chef Server to join
  chef_server "https://chef.example.com/organizations/#{business_unit}"

  # The chef environment the machine will live in
  chef_environment target_chef_environment

  # The bootstrap runlist
  role 'base'
  role "#{site}"
  role "#{business_unit}-#{component}"

  # Options that we need to pass through to the driver;
  # These are very specific to the vCenter Orchestrator workflow we're
  # using to handle the machine allocation.
  machine_options ({
    :reservation_policy => reservation_policy,
    :on_behalf_of       => on_behalf_of,
    :location           => site,
    :environment        => target_chef_environment,
    :component          => component,
    :cpu                => cpu_count,
    :ram                => ram_mb,
    :image              => vm_template,
    :is_windows         => false
  })
end
