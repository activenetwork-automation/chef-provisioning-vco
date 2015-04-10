require 'chef/provisioning/vco_driver/driver'

Chef::Provisioning.register_driver_class('vco', Chef::Provisioning::VcoDriver::Driver)
