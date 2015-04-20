require 'chef/provisioning/driver'
require 'chef/provisioning/version'
require 'chef/provisioning/machine/basic_machine'
require 'chef/provisioning/machine/unix_machine'
require 'chef/provisioning/machine/windows_machine'
require 'chef/provisioning/vco_driver/defaults'
require 'chef/provisioning/vco_driver/version'
require 'chef/provisioning/transport/ssh'
require 'chef/provisioning/transport/winrm'
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
          super(driver_url, config)

          Chef::Log.debug "Initializing vco_driver..."

          _, @tenant, @business_unit = driver_url.split(/:/)

          Chef::Log.debug "vco driver: tenant = '#{@tenant}'; business unit = '#{@business_unit}'"

          # Merge driver option defaults with given options.
          @driver_options = DEFAULT_DRIVER_OPTIONS.merge(config[:driver_options])
          Chef::Log.debug "vco driver: options set to: #{@driver_options}"

          # Set max_wait from the driver options
          @max_wait      = @driver_options[:vco_options][:max_wait]
          @wait_interval = @driver_options[:vco_options][:wait_interval]

          Chef::Log.debug "vco driver: max_wait set to #{@max_wait} seconds."
          Chef::Log.debug "vco driver: wait_interval set to #{@wait_interval} seconds."
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

            # See if we've provisoned this already
            # If we have, make sure the machine is up, then return.
            if machine_spec.reference['vm_uuid'] && !machine_spec.reference['vm_uuid'].nil?
              Chef::Log.debug("Machine #{machine_spec.name} should already exist; starting...")
              start_machine(action_handler, machine_spec, machine_options)
              return machine_spec
            end
            
            # Apparently it doesn't exist yet, so we need to make one.
            # Construct the workflow
            Chef::Log.debug "Creating workflow request for #{machine_spec.name}..."
            workflow = VcoWorkflows::Workflow.new(@driver_options[:vco_options][:workflows][:allocate_machine][:name],
                                                  id: @driver_options[:vco_options][:workflows][:allocate_machine][:id],
                                                  service: workflow_service_for(@driver_options))

            # Set the parameters to create the machine
            workflow.parameters = {
              'nodename'          => machine_spec.name,
              'tenant'            => @tenant,
              'businessUnit'      => @business_unit,
              'reservationPolicy' => machine_options[:reservation_policy],
              'environment'       => machine_options[:environment],
              'onBehalfOf'        => machine_options[:on_behalf_of],
              'location'          => machine_options[:location],
              'component'         => machine_options[:component],
              'coreCount'         => machine_options[:cpu],
              'ramMB'             => machine_options[:ram],
              'image'             => machine_options[:image]
            }

            # Execute the workflow
            Chef::Log.debug "Submitting provisioning workflow execution for #{machine_spec.name}"
            workflow.execute

            # Create our reference data
            machine_spec.reference = {
              'driver_url' => driver_url,
              'driver_version' => Chef::Provisioning::VcoDriver::VERSION,
              'allocated_at' => Time.now.utc.to_s,
              'host_node' => action_handler.host_node,
              'vco_url' => @driver_options[:vco_options][:url],
              'workflow_name' => workflow.name,
              'workflow_id' => workflow.id,
              'execution_id' => workflow.execution_id,
              'cpu' => machine_options[:cpu],
              'ram' => machine_options[:ram],
              'image' => machine_options[:image]
            }
            machine_spec.reference['is_windows'] = machine_options[:is_windows] if machine_options[:is_windows]
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

            # ============================
            # Ensure the machine was built
            # ============================

            # First check machine_spec to see if it's already got a name and uuid.
            # If it does, then can check to see if the machine is alive, and simply carry on
            Chef::Log.debug "Checking for existing instance of #{machine_spec.name}..."
            instance = instance_for(machine_spec, machine_options)

            if instance.nil?
              Chef::Log.debug "No instance for #{machine_spec.name} found."
              wait_for_machine(machine_spec, machine_options)
            end

            # ===========================
            # Ensure the machine is ready
            # ===========================

            # If that was successful, build the machine object
            Chef::Log.debug "Creating Machine object for instance #{machine_spec.name}"
            machine_for(machine_spec, machine_options, instance)
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
          raise "Whoops, somebody didn't implement connect_to_machine!"
        end


        # Delete the given machine --  destroy the machine,
        # returning things to the state before allocate_machine was called.
        #
        # @param [Chef::Provisioning::ActionHandler] action_handler The action_handler object that is calling this method
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        def destroy_machine(action_handler, machine_spec, machine_options)
          action_handler.perform_action "Destroy #{machine_spec.name} tenant #{@tenant}, business unit #{@business_unit}" do
            Chef::Log.debug "Destroying instance #{machine_spec.name}..."

            # Make sure there's something to destroy
            instance = instance_for(machine_spec, machine_options)

            if instance.nil?
              Chef::Log.debug "Instance #{machine_spec.name} does not seem to exist, nothing to destroy."
              return
            end

            # Apparently it doesn't exist yet, so we need to make one.
            # Construct the workflow
            Chef::Log.debug "Creating workflow to destroy #{machine_spec.name}"
            workflow = VcoWorkflows::Workflow.new(@driver_options[:vco_options][:workflows][:destroy_machine][:name],
                                                  id: @driver_options[:vco_options][:workflows][:destroy_machine][:id],
                                                  service: workflow_service_for(@driver_options))
            workflow.parameters = {
              'vmName' => machine_spec.reference['vm_name'],
              'vmUuid' => machine_spec.reference['vm_uuid']
            }

            # Fire and forget.
            Chef::Log.debug "Executing workflow to destroy #{machine_spec.name}"
            workflow.execute
          end
        end

        # Stop the machine.
        #
        # @param [Chef::Provisioning::ActionHandler] action_handler The action_handler object that is calling this method
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        # @param [Boolean] wait Whether to wait for the shutdown to complete or not.
        def stop_machine(action_handler, machine_spec, machine_options, wait = false)
          action_handler.perform_action "Stopping machine #{machine_spec.name}" do
            Chef::Log.debug "Stopping machine #{machine_spec.name}"

            # See if it exists and is running
            instance = instance_for(machine_spec, machine_options)

            if instance.nil?
              Chef::Log.debug "Instance #{machine_spec.name} does not seem to exist, nothing to stop."

            end

            # Construct the workflow
            Chef::Log.debug "Creating workflow to stop #{machine_spec.name}..."
            workflow = VcoWorkflows::Workflow.new(@driver_options[:vco_options][:workflows][:stop_machine][:name],
                                                  id: @driver_options[:vco_options][:workflows][:stop_machine][:id],
                                                  service: workflow_service_for(@driver_options))
            workflow.parameters = {
              'vmName' => machine_spec.reference['vm_name'],
              'vmUuid' => machine_spec.reference['vm_uuid']
            }

            # Fire and forget.
            Chef::Log.debug "Executing workflow to destroy #{machine_spec.name}"
            workflow.execute
          end
        end

        # Start the machine
        #
        # @param [Chef::Provisioning::ActionHandler] action_handler The action_handler object that is calling this method
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        # @param [Boolean] wait Whether to wait for the startup to complete or not.
        def start_machine(action_handler, machine_spec, machine_options, wait = false)
          action_handler.perform_action "Ensuring #{machine_spec.name} is started..." do
            Chef::Log.debug "Starting instance with machine_spec reference #{machine_spec[:reference]}"

            unless machine_spec.reference['vm_uuid'] && machine_spec.reference['vm_name']
              raise "Unable to find VM data to start #{machine_spec.name}!"
            end

            # No point in starting a machine that's already running...
            instance = instance_for(machine_spec, machine_options)
            if instance[:guest_state].eql?('running')
              Chef::Log.debug "Instance #{machine_spec.name} is already running. Nothing to do."
              return
            end

            # Retrieve the start_machine workflow
            workflow = VcoWorkflows::Workflow.new(@driver_options[:vco_options][:workflows][:start_machine][:name],
                                                  id: @driver_options[:vco_options][:workflows][:start_machine][:id],
                                                  service: workflow_service_for(@driver_options))
            workflow.parameters = {
              'vmName' => machine_spec.reference['vm_name'],
              'vmUuid' => machine_spec.reference['vm_uuid']
            }
            workflow.execute

            return unless wait
            wf_token = wait_for_workflow(workflow.token)

            # If execution state comes back with failed, we need to bail
            raise "Workflow failed for #{machine_spec.name}!" if wf_token.state.match?(/failed/i)

            # If execution state is still in something "still running", bail on wait timeout.
            # Note: when execution is completed wf_token.alive? will be false.
            raise "Workflow wait timeout for #{machine_spec.name}" if wf_token.alive?


          end
        end

        # Create a machine object
        #
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        # @param [Hash] instance An "instance" hash describing live data about the VM
        # @return [Chef::Provisioning::Machine]
        def machine_for(machine_spec, machine_options, instance = nil)
          instance ||= instance_for(machine_spec, machine_options)

          if !instance
            raise "Instance for node #{machine_spec.name} has not been created!"
          end

          if machine_spec.reference['is_windows']
            Chef::Provisioning::Machine::WindowsMachine.new(machine_spec, transport_for(machine_spec, machine_options, instance), convergence_strategy_for(machine_spec, machine_options))
          else
            Chef::Provisioning::Machine::UnixMachine.new(machine_spec, transport_for(machine_spec, machine_options, instance), convergence_strategy_for(machine_spec, machine_options))
          end
        end

        # Create an "instance", basically a hash of useful information about the machine
        #
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        # @return [Hash]
        def instance_for(machine_spec, machine_options)
          # If the vm name and uuid don't yet exist, we can't get instance data
          return nil unless machine_spec.reference.has_key?['vm_name'] && machine_spec.reference.has_key?['vm_uuid']

          # Create the workflow object to get the VM info for the instance
          workflow = VcoWorkflows::Workflow.new(@driver_options[:vco_options][:workflows][:get_machine_info][:name],
                                                id: @driver_options[:vco_options][:workflows][:get_machine_info][:id],
                                                service: workflow_service_for(@driver_options))

          workflow.parameters = {
            'vmName' => machine_spec.reference['vm_name'],
            'vmUuid' => machine_spec.reference['vm_uuid']
          }
          workflow.execute

          wf_token = wait_for_workflow(workflow.token)
          return nil if wf_token.state.match(/failed/i)

          {
            host_name:       wf_token.output_parameters['hostName'],
            ip_address:      wf_token.output_parameters['ipAddress'],
            vm_host:         wf_token.output_parameters['vmHost'],
            boot_time:       wf_token.output_parameters['bootTime'],
            power_state:     wf_token.output_parameters['powerState'],
            clean_power_off: wf_token.output_parameters['cleanPowerOff'],
            online_standby:  wf_token.output_parameters['onlineStandBy'],
            guest_state:     wf_token.output_parameters['guestState']
          }
        end

        # Get an appropriate transport for the machine
        # Stolen gratuitously from Chef::Provisioning::AwsDriver
        #
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        # @return [Chef::Provisioning::Transport::SSH]
        def transport_for(machine_spec, machine_options, instance)
          # if machine_options.has_key?(:transport) && machine_options[:transport].eql?(:vmtools)
          #   create_vmtools_transport(machine_spec, machine_options, instance)
          # elsif machine_spec.reference['is_windows']
          if machine_spec.reference['is_windows']
            create_winrm_transport(machine_spec, machine_options, instance)
          else
            create_ssh_transport(machine_spec, machine_options, instance)
          end
        end

        # Create an SSH transport
        # Stolen gratuitously from Chef::Provisioning::AwsDriver
        #
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        # @return [Chef::Provisioning::Transport::SSH]
        def create_ssh_transport(machine_spec, machine_options, instance)
          # ssh_options = ssh_options_for(machine_spec, machine_options, instance)
          ssh_options = nil
          username = machine_spec.reference['ssh_username'] || machine_options[:ssh_username] || default_ssh_username
          if machine_options.has_key?(:ssh_username) && machine_options[:ssh_username] != machine_spec.reference['ssh_username']
            Chef::Log.warn("Server #{machine_spec.name} was created with SSH username #{machine_spec.reference['ssh_username']} and machine_options specifies username #{machine_options[:ssh_username]}.  Using #{machine_spec.reference['ssh_username']}.  Please edit the node and change the chef_provisioning.reference.ssh_username attribute if you want to change it.")
          end
          options = {}
          if machine_spec.reference[:sudo] || (!machine_spec.reference.has_key?(:sudo) && username != 'root')
            options[:prefix] = 'sudo '
          end

          # remote_host = determine_remote_host(machine_spec, instance)
          remote_host = instance[:ip_address]

          #Enable pty by default
          options[:ssh_pty_enable] = true
          options[:ssh_gateway] = machine_spec.reference['ssh_gateway'] if machine_spec.reference.has_key?('ssh_gateway')

          Chef::Provisioning::Transport::SSH.new(remote_host, username, ssh_options, options, config)
        end

        # Create a WinRM Transport
        # Stolen gratuitously from Chef::Provisioning::AwsDriver
        #
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        # @return [Chef::Provisioning::Transport::WinRM]
        def create_winrm_transport(machine_spec, machine_options, instance)
          # remote_host = determine_remote_host(machine_spec, instance)
          remote_host = instance[:ip_address]

          port = machine_spec.reference['winrm_port'] || 5985
          endpoint = "http://#{remote_host}:#{port}/wsman"
          type = :plaintext
          pem_bytes = get_private_key(instance.key_name)
          encrypted_admin_password = wait_for_admin_password(machine_spec)

          decoded = Base64.decode64(encrypted_admin_password)
          private_key = OpenSSL::PKey::RSA.new(pem_bytes)
          decrypted_password = private_key.private_decrypt decoded

          winrm_options = {
            :user => machine_spec.reference['winrm_username'] || 'Administrator',
            :pass => decrypted_password,
            :disable_sspi => true,
            :basic_auth_only => true
          }

          Chef::Provisioning::Transport::WinRM.new("#{endpoint}", type, winrm_options, {})
        end

        # Private methods start here

        private

        # Create a workflow service object by using the defined driver options
        #
        # @param [Hash] driver_options
        # @return [VcoWorkflows::WorkflowService]
        def workflow_service_for(driver_options = {})
          Chef::Log.debug("Generating workflow service for #{driver_options[:vco_options][:url]}")
          vcosession = VcoWorkflows::VcoSession.new(driver_options[:vco_options][:url],
                                                    user:       driver_options[:vco_options][:username],
                                                    password:   driver_options[:vco_options][:password],
                                                    verify_ssl: driver_options[:vco_options][:verify_ssl])
          VcoWorkflows::WorkflowService.new(vcosession)
        end

        # Wait for a workflow execution to complete
        #
        # @param [VcoWorkflows::WorkflowToken] wf_token WorkflowToken for the execution you are waiting for
        # @return [VcoWorkflows::WorkflowTokwn] Updated token
        def wait_for_workflow(wf_token)
          # See what the result was for the workflow execution. It may not be
          # done yet, so we're going to have to wait around for it to finish.
          start_wait = Time.now
          while wf_token.alive? && (Time.now - start_wait < @max_wait)
            sleep @wait_interval
            Chef::Log.debug("Checking status of workflow #{wf_token.workflow_id} / #{wf_token.id}")
            wf_token = VcoWorkflows::WorkflowToken.new(workflow_service_for(@driver_options),
                                                       wf_token.workflow_id,
                                                       wf_token.id)
          end
          Chef::Log.debug("Wait timeout while waiting for #{wf_token.workflow_id} / #{wf_token.id}") if wf_token.alive?

          # Return the updated token
          wf_token
        end

        # Wait for a machine that is building
        #
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        def wait_for_machine(machine_spec, machine_options)
          # Get the WorkflowToken for our execution, so we can get some additional
          # information to locate our VM. If the VM request isn't complete yet, we need to
          # hang around and wait for it to complete. Stop waiting when we hit our max_wait
          # timeout.
          Chef::Log.debug("Waiting for #{machine_spec.name} to complete provisioning...")
          Chef::Log.debug("Requesting completion data for workflow #{machine_spec.reference['workflow_id']}, execution #{machine_spec.reference['execution_id']}")
          wf_token   = VcoWorkflows::WorkflowToken.new(workflow_service_for(@driver_options),
                                                       machine_spec.reference['workflow_id'],
                                                       machine_spec.reference['execution_id'])
          Chef::Log.debug('Will wait for completion of workflow...')
          wf_token = wait_for_workflow(wf_token)

          # If execution state comes back with failed, we need to bail
          raise "Workflow failed for #{machine_spec.name}!" if wf_token.state.match?(/failed/i)

          # If execution state is still in something "still running", bail on wait timeout.
          # Note: when execution is completed wf_token.alive? will be false.
          raise "Workflow wait timeout for #{machine_spec.name}" if wf_token.alive?

          Chef::Log.debug("Provisioning for #{machine_spec.name} appears to have succeeded.")
          # Get the vm name and uuid from the workflow output parameters.
          # These are arrays, but should only have a single element for our VM.
          vm_uuids = wf_token.output_parameters['provisionedVmUuids']
          vm_names = wf_token.output_parameters['provisionedVmNames']

          # Sanity check, we should have the same number of names to uuids (1:1)
          if vm_uuids.length != vm_names.length
            raise "Provisioned VM UUID count doesn't match provisioned VM Name count."
          end

          # And we should only have a single VM in the result set
          if vm_uuids.length > 1 || vm_names.length > 1
            raise "#{machine_spec.name} provisioned by #{wf_token.name} request #{wf_token.id} resulted in multiple VMs!"
          end

          # Everything looks good, let's grab and save the name and uuid for future reference.
          # We need to add the VM uuid because there's a possibility that the execution_id
          # we saved in allocate_machine could go away if something on the Orchestrator
          # server changes, and we don't want that to trigger a re-allocation for something
          # that already exists.
          Chef::Log.debug("Provisioned #{machine_spec.name}, vm_name #{vm_names.first}, vm_uuid #{vm_uuids.first}")
          machine_spec.reference['vm_uuid'] = vm_uuids.first
          machine_spec.reference['vm_name'] = vm_names.first

          # Save it
          Chef::Log.debug("Saving machine_spec for #{machine_spec.name}")
          machine_spec.save(action_handler)
        end
      end
    end
  end
end
