require 'chef/provisioning/vco_driver'

with_driver 'vco:atom-active:ref2', :vco_options => {
  url:        'https://vcoserver.example.com:8281/',
  verify_ssl: false,
  username:   'joeuser',
  password:   'passwords_suck'
}

components = %q(webserver apiserver dbserver)

machine_batch do
  components.each do |component|
    component_role = "#{vco_options[:business_unit]}-#{component}"
    1.upto(cluster_size).do |i| do
      machine "#{chef_environment}-#{component}-#{i}" do
        machine_options :reservation_policy => 'nonprod',
                        :on_behalf_of => 'svc_vco@example.com',
                        :location => 'uswest',
                        :environment => chef_environment,
                        :component => component,
                        :cpu => compute[component][:cpu],
                        :ram => compute[component][:ram],
                        :image => compute[component][:image]
        run_list ['role[active-base]', "role[loc_#{location}]", component_role]
      end
    end
  end
end
