# Build a single machine using chef provisioning with vco driver

require 'chef/provisioning/vco_driver'

with_driver("vco:atom-active:ref2", {
  vco_options: {
    url:           'https://vco.example.com:8281/',
    verify_ssl:    false,
    username:      'EXAMPLE\user',
    password:      'password',
    max_wait:      900,
    wait_interval: 15
  }
})

with_machine_options({
  ssh_username:      'knife',
  sudo:              true,
  is_windows:        false,
  image:             'centos-6.6-x86_64-20150325-1',
  bootstrap_options: {
    key_path:           File.join(ENV['HOME'], '.ssh', 'knife_rsa'),
    reservation_policy: 'nonprod',
    on_behalf_of:       'svc.vco@dev.atom.int',
    environment:        'lab1',
    component:          'webserver',
    cpu:                1,
    ram:                1024
  }
})

with_chef_server('https://chef.example.com/organizations/myorg')

# Build the machine
machine 'webserver01' do
  role 'site'
  role 'base'
  role 'webserver'

  chef_environment 'lab1'
end
