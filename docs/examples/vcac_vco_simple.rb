require 'chef/provisioning/vco_driver'

with_driver 'vco:atom-active:ref2', :vco_options => {
  url:        'https://vcoserver.example.com:8281/',
  verify_ssl: false,
  username:   'joeuser',
  password:   'passwords_suck'
}

components = %q(webserver apiserver dbserver)

case chef_environment
when 'int', 'qa', 'stage'
  cluster_size = 2
when 'prod'
  cluster_size = 4
else
  cluster_size = 1
end

machine_batch do
  components.each do |component|
    component_role = "#{vco_options[:business_unit]}-#{component}"
    1.upto(cluster_size).do |i| do
      machine "#{chef_environment}-#{component}-#{i}" do
        machine_options bootstrap_options: {
          reservation_policy: 'nonprod',
          environment:        chef_environment,
          on_behalf_of:       'svc_vco@example.com',
          location:           'uswest',
          component:          component,
          cpu:                1,
          ram:                512,
          image:              nil
        }
        role 'loc_uswest'
        role 'active-base'
        role component_role
      end
    end
  end
end
