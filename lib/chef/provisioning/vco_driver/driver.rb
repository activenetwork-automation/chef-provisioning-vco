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
        #
        attr_reader :tenant
        attr_reader :business_unit
        attr_reader :driver_options

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

          @driver_options = config[:driver_options]
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
          bootstrap_options = bootstrap_options_for(action_handler, machine_spec, machine_options)

          #
          action_handler.perform_action "Create #{machine_spec.name} with template #{bootstrap_options[:image]}, tenant #{@tenant}, business unit #{@business_unit}" do
            Chef::Log.debug "Creating instance with bootstrap options #{bootstrap_options}"

            workflow = VcoWorkflows::Workflow.new(bootstrap_options[:workflow_name],
                                                  id:         bootstrap_options[:workflow_id],
                                                  url:        @driver_options[:vco_options][:url],
                                                  username:   @driver_options[:vco_options][:username],
                                                  password:   @driver_options[:vco_options][:password],
                                                  verify_ssl: @driver_options[:vco_options][:verify_ssl])

            params                      = {}
            params['nodename']          = machine_spec.name
            params['tenant']            = @tenant
            params['businessUnit']      = @business_unit
            params['reservationPolicy'] = bootstrap_options[:reservation_policy]
            params['environment']       = bootstrap_options[:environment]
            params['onBehalfOf']        = bootstrap_options[:on_behalf_of]
            params['location']          = bootstrap_options[:location]
            params['component']         = bootstrap_options[:component]
            params['coreCount']         = bootstrap_options[:cpu]
            params['ramMB']             = bootstrap_options[:ram]
            params['image']             = bootstrap_options[:image]

            workflow.parameters = params
            workflow.execute

            machine_spec.reference = {
              'driver_url' => driver_url,
              'driver_version' => Chef::Provisioning::VcoDriver::VERSION,
              'allocated_at' => Time.now.utc.to_s,
              'host_node' => action_handler.host_node,
              'image' => bootstrap_options[:image],
              'vco_url' => @driver_options[:vco_options][:url],
              'workflow_name' => workflow.name,
              'workflow_id' => workflow.id,
              'execution_id' => workflow.execution_id
            }

            machine_spec.reference
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

            # First we need the workflow object for the workflow that was used to create the
            # machine. Since we know what the workflow_id is due to machine_spec, we ignore
            # the workflow name parameter (see VcoWorkflows::Workflow#initialize)
            workflow = VcoWorkflows::Workflow.new(nil,
                                                  id:         machine_spec[:reference]['workflow_id'],
                                                  url:        @driver_options[:vco_options][:url],
                                                  username:   @driver_options[:vco_options][:username],
                                                  password:   @driver_options[:vco_options][:password],
                                                  verify_ssl: @driver_options[:vco_options][:verify_ssl])

            # Now, we get the WorkflowToken for our execution, so we can get some additional
            # information to locate our VM. If the VM request isn't complete yet, we need to
            # hang around and wait for it to complete.
            wf_token = worfklow.token(machine_spec.reference['execution_id'])
            while wf_token.alive?
              sleep 5
              wf_token = workflow.token(wf_token.id)
            end

            raise "Failed to provision #{machine_spec.name}!" if wf_token.state.match?(/failed/i)

            wf_token = workflow.token(machine_spec[:reference]['execution_id'])
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

        # Calculate the bootstrap options
        #
        # @param [Chef::Provisioning::ActionHandler] action_handler The action_handler object that is calling this method
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        def bootstrap_options_for(action_handler, machine_spec, machine_options)
          bootstrap_options = (machine_options[:bootstrap_options] || {}).to_h.dup
          image = bootstrap_options[:image] || machine_options[:image]
          bootstrap_options[:image] = image

          # if machine_options[:is_windows]
          #   Chef::Log.debug "Setting WinRM userdata..."
          #   bootstrap_options[:user_data] = user_data
          # else
          #   Chef::Log.debug "Non-windows, not setting userdata"
          # end
          bootstrap_options
        end
      end
    end
  end
end
