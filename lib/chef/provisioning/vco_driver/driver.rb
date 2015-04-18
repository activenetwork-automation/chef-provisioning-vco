require 'chef/provisioning/driver'
require 'chef/provisioning/version'
require 'chef/provisioning/machine/basic_machine'
require 'chef/provisioning/machine/unix_machine'
require 'chef/provisioning/machine/windows_machine'
require 'chef/provisioning/vco_driver/version'
require 'vcoworkflows'

class Chef
  #
  module Provisioning
    #
    module VcoDriver
      #
      class Driver < Chef::Provisioning::Driver
        # vRA Tenant name
        attr_reader :tenant

        # vRA Tenant Business Group name
        attr_reader :business_unit

        # Chef Provisioning Driver Options
        attr_reader :driver_options
        attr_reader :driver_defaults

        # Max wait time (for things like ready_machine)
        attr_accessor :max_wait

        # How long to wait between checks when waiting for something
        attr_accessor :wait_interval

        # URL scheme:
        # vco:tenant:business_unit
        # i.e.:
        # vco:atom-active:soi
        # where 'ref1' is the name of a business unit for a tenant inside your
        # vRealize environment. At this point we don't yet support multi-tenancy
        # and rely upon using the default tenant.
        def self.from_url(driver_url, config)
          Driver.new(driver_url, config)
        end

        #
        # = Driver Options
        # - url - URL to the vCenter/vRealize Orchestrator server (https://vco.example.com:8281/)
        # - username - vCO user name
        # - password - vCO password
        # - verify_ssl - whether to verify TLS certificates (defaults to true)
        #
        def initialize(driver_url, config)
          super

          _, @tenant, @business_unit = driver_url.split(/:/)

          # Merge driver option defaults with given options.
          @driver_options = {
            url: nil,
            username: nil,
            password: nil,
            verify_ssl: true,
            max_wait: 600
          }.merge(config[:driver_options])

          @max_wait = @driver_options[:max_wait]
        end

        def self.canonicalize_url(driver_url, config)
          [ driver_url, config ]
        end

        # Allocate a machine from the underlying service.  This method
        # does not need to wait for the machine to boot or have an IP, but it must
        # store enough information in machine_spec.reference to find the machine
        # later in ready_machine.
        #
        # If a machine is powered off or otherwise unusable, this method may start
        # it, but does not need to wait until it is started.  The idea is to get the
        # gears moving, but the job doesn't need to be done :)
        #
        # @param [Chef::Provisioning::ActionHandler] action_handler The action_handler object that is calling this method
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired options when
        # constructing the machine
        #
        # @return [Chef::Provisioning::ManagedEntry] Modifies the passed-in machine_spec.  Anything in here will be saved
        # back after allocate_machine completes.
        #
        def allocate_machine(action_handler, machine_spec, machine_options)
          #
          action_handler.perform_action "Create #{machine_spec.name} with template #{machine_options[:image]}, tenant #{@tenant}, business unit #{@business_unit}" do
            Chef::Log.debug "Creating instance with bootstrap options #{machine_options}"
            
            # Pull in per-machine overrides for driver options (if they exist)
            driver_options = @driver_options.merge(machine_options[:vco_options]) if machine_options[:vco_options]

            workflow = VcoWorkflows::Workflow.new(machine_options[:workflow_name],
                                                  id:         machine_options[:workflow_id],
                                                  url:        driver_options[:vco_options][:url],
                                                  username:   driver_options[:vco_options][:username],
                                                  password:   driver_options[:vco_options][:password],
                                                  verify_ssl: driver_options[:vco_options][:verify_ssl])

            params                      = {}
            params['nodename']          = machine_spec.name
            params['tenant']            = @tenant
            params['businessUnit']      = @business_unit
            params['reservationPolicy'] = machine_options[:reservation_policy]
            params['environment']       = machine_options[:environment]
            params['onBehalfOf']        = machine_options[:on_behalf_of]
            params['location']          = machine_options[:location]
            params['component']         = machine_options[:component]
            params['coreCount']         = machine_options[:cpu]
            params['ramMB']             = machine_options[:ram]
            params['image']             = machine_options[:image]

            workflow.parameters = params
            workflow.execute

            machine_spec.reference = {
              'driver_url' => driver_url,
              'driver_version' => Chef::Provisioning::VcoDriver::VERSION,
              'allocated_at' => Time.now.utc.to_s,
              'host_node' => action_handler.host_node,
              'vco_url' => driver_options[:vco_options][:url],
              'workflow_name' => workflow.name,
              'workflow_id' => workflow.id,
              'execution_id' => workflow.execution_id,
              'reservation_policy' => machine_options[:reservation_policy],
              'on_behalf_of' => machine_options[:on_behalf_of],
              'location' => machine_options[:location],
              'cpu' => machine_options[:cpu],
              'ram' => machine_options[:ram],
              'image' => machine_options[:image]
            }
          end
        end

        # Ready a machine, to the point where it is running and accessible via a
        # transport. This will NOT allocate a machine, but may kick it if it is down.
        # This method waits for the machine to be usable, returning a Machine object
        # pointing at the machine, allowing useful actions like setup, converge,
        # execute, file and directory.
        #
        #
        # @param [Chef::Provisioning::ActionHandler] action_handler The action_handler object that is calling this method
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        #
        # @return [Machine] A machine object pointing at the machine, allowing useful actions like setup,
        # converge, execute, file and directory.
        #
        def ready_machine(action_handler, machine_spec, machine_options)
          action_handler.perform_action "Making #{machine_spec.name} ready" do
            Chef::Log.debug "Readying instance with machine_spec reference #{machine_spec[:reference]}"

            # Pull in per-machine overrides for driver options (if they exist)
            driver_options = @driver_options.merge(machine_options[:vco_options]) if machine_options[:vco_options]
            
            # First we need the workflow object for the workflow that was used to create the
            # machine. Since we know what the workflow_id is due to machine_spec, we ignore
            # the workflow name parameter (see VcoWorkflows::Workflow#initialize)
            workflow = VcoWorkflows::Workflow.new(machine_spec.reference['workflow_name'],
                                                  id:         machine_spec.reference['workflow_id'],
                                                  url:        driver_options[:vco_options][:url],
                                                  username:   driver_options[:vco_options][:username],
                                                  password:   driver_options[:vco_options][:password],
                                                  verify_ssl: driver_options[:vco_options][:verify_ssl])

            # Now, we get the WorkflowToken for our execution, so we can get some additional
            # information to locate our VM. If the VM request isn't complete yet, we need to
            # hang around and wait for it to complete. Stop waiting when we hit our max_wait
            # timeout.
            wf_token = worfklow.token(machine_spec.reference['execution_id'])
            start_wait = Time.now
            while wf_token.alive? && (Time.now - start_wait < @max_wait)
              sleep 10
              wf_token = workflow.token(wf_token.id)
            end

            # If execution state comes back with failed, we need to bail
            raise "Failed to provision #{machine_spec.name}!" if wf_token.state.match?(/failed/i)

            # If execution state is still in something "still running", bail on wait timeout.
            # Note: when execution is completed wf_token.alive? will be false.
            raise "Wait timeout for #{machine_spec.name}" if wf_token.alive?

            # Grab the VM name and UUID from the workflow output parameters, so we can attach
            # directly to the VM from this point forward
            machine_spec.reference['vm_uuid'] = wf_token.output_parameters['provisionedVmUuid'] if wf_token.output_parameters['provisionedVmUuid']
            machine_spec.reference['vm_name'] = wf_token.output_parameters['provisionedVmName'] if wf_token.output_parameters['provisionedVmName']

            # Okay, now build a Machine object!

          end
        end

        # Connect to a machine without allocating or readying it.  This method will
        # NOT make any changes to anything, or attempt to wait.
        #
        # @param [Chef::Provisioning::ManagedEntry] machine_spec ManagedEntry representing this machine.
        # @param [Hash] machine_options
        # @return [Machine] A machine object pointing at the machine, allowing useful actions like setup,
        # converge, execute, file and directory.
        #
        def connect_to_machine(machine_spec, machine_options)

        end


        # Delete the given machine --  destroy the machine,
        # returning things to the state before allocate_machine was called.
        #
        # @param [Chef::Provisioning::ActionHandler] action_handler The action_handler object that is calling this method
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        def destroy_machine(action_handler, machine_spec, machine_options)

        end

        # Stop the given machine.
        #
        # @param [Chef::Provisioning::ActionHandler] action_handler The action_handler object that is calling this method
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        def stop_machine(action_handler, machine_spec, machine_options)

        end
      end
    end
  end
end
