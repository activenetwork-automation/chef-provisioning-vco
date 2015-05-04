# Driver default settings
class Chef
  module Provisioning
    module VcoDriver
      #
      # Defaults for Chef::Provisioning::VcoDriver::Driver
      #
      module Constants
        #
        # Default driver options
        #

        # Initialize the hash
        DEFAULT_DRIVER_OPTIONS = {
          vco_options: {
            workflows: {
              allocate_machine: {},
              start_machine:    {},
              stop_machine:     {},
              destroy_machine:  {},
              get_machine_info: {}
            }
          }
        }

        # Orchestrator URL
        # This should be in the form https://#{fqdn}:#{port}/
        # i.e., https://vcoserver.example.com:8281/
        DEFAULT_DRIVER_OPTIONS[:vco_options][:url]                                 = nil

        # vCO username
        DEFAULT_DRIVER_OPTIONS[:vco_options][:username]                            = nil

        # vCO password
        DEFAULT_DRIVER_OPTIONS[:vco_options][:password]                            = nil

        # Verify TLS certificate authenticity?
        DEFAULT_DRIVER_OPTIONS[:vco_options][:verify_ssl]                          = true

        # Limit for how long we'll wait for any workflow to execute before giving up
        DEFAULT_DRIVER_OPTIONS[:vco_options][:max_wait]                            = 600

        # Interval for how frequently we'll check on a waiting task
        DEFAULT_DRIVER_OPTIONS[:vco_options][:wait_interval]                       = 15

        # Workflow for allocate_machine
        DEFAULT_DRIVER_OPTIONS[:vco_options][:workflows][:allocate_machine][:name] = 'allocate_machine'
        DEFAULT_DRIVER_OPTIONS[:vco_options][:workflows][:allocate_machine][:id]   = '708bf42d-2eb5-4dec-b511-e8295b66245b'

        # Workflow for ready_machine
        DEFAULT_DRIVER_OPTIONS[:vco_options][:workflows][:ready_machine][:name]    = 'ready_machine'
        DEFAULT_DRIVER_OPTIONS[:vco_options][:workflows][:ready_machine][:id]      = 'd2065000-d7cc-4719-be9e-4f7318ccf708'

        # Workflow for start_machine
        DEFAULT_DRIVER_OPTIONS[:vco_options][:workflows][:start_machine][:name]    = 'start_machine'
        DEFAULT_DRIVER_OPTIONS[:vco_options][:workflows][:start_machine][:id]      = 'd2065000-d7cc-4719-be9e-4f7318ccf708'

        # Workflow for stop_machine
        DEFAULT_DRIVER_OPTIONS[:vco_options][:workflows][:stop_machine][:name]     = 'stop_machine'
        DEFAULT_DRIVER_OPTIONS[:vco_options][:workflows][:stop_machine][:id]       = '0ff83a4d-c0c4-451f-9077-cf7d58cfb01a'

        # Workflow for destroy_machine
        DEFAULT_DRIVER_OPTIONS[:vco_options][:workflows][:destroy_machine][:name]  = 'destroy_machine'
        DEFAULT_DRIVER_OPTIONS[:vco_options][:workflows][:destroy_machine][:id]    = '14675651-a466-4ef2-b176-8ddc3a0a4bef'

        # Workflow for get_machine_info (used in instance_for)
        DEFAULT_DRIVER_OPTIONS[:vco_options][:workflows][:get_machine_info][:name] = 'get_machine_info'
        DEFAULT_DRIVER_OPTIONS[:vco_options][:workflows][:get_machine_info][:id]   = 'ae6fa6e2-7aa7-4cff-81b3-f18f9d9468e9'
      end
    end
  end
end
