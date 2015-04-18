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
          super(driver_url, config)

          _, @tenant, @business_unit = driver_url.split(/:/)

          # Set our defaults for driver options
          @driver_defaults = {
            vco_options: {
              url: nil,
              username: nil,
              password: nil,
              verify_ssl: true,
              max_wait: 600,
              wait_interval: 15,
              workflows: {
                allocate_machine: {
                  name: 'allocate_machine',
                  id:   '708bf42d-2eb5-4dec-b511-e8295b66245b'
                },
                ready_machine:    {
                  name: 'ready_machine',
                  id:   'd2065000-d7cc-4719-be9e-4f7318ccf708'
                },
                start_machine:    {
                  name: 'start_machine',
                  id:   'd2065000-d7cc-4719-be9e-4f7318ccf708'
                },
                stop_machine:     {
                  name: 'stop_machine',
                  id:   '0ff83a4d-c0c4-451f-9077-cf7d58cfb01a'
                },
                destroy_machine:  {
                  name: 'destroy_machine',
                  id:   'b5ddf095-7615-4351-9f9c-b33fb0ff215c'
                }
              }
            }
          }

          # Merge driver option defaults with given options.
          @driver_options = @driver_defaults.merge(config[:driver_options])

          # Set max_wait from the driver options
          @max_wait      = @driver_options[:vco_options][:max_wait]
          @wait_interval = @driver_options[:vco_options][:wait_interval]
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
              start_machine(action_handler, machine_spec, machine_options)
              return machine_spec
            end
            
            # Apparently it doesn't exist yet, so we need to make one.
            # Construct the workflow
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

            # Get the WorkflowToken for our execution, so we can get some additional
            # information to locate our VM. If the VM request isn't complete yet, we need to
            # hang around and wait for it to complete. Stop waiting when we hit our max_wait
            # timeout.
            wf_token   = VcoWorkflows::WorkflowToken.new(workflow_service_for(@driver_options),
                                                         machine_spec.reference['workflow_id'],
                                                         machine_spec.reference['execution_id'])
            wf_token = wait_for_workflow(wf_token)

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
            machine_spec.reference['vm_uuid'] = vm_uuids.first
            machine_spec.reference['vm_name'] = vm_names.first

            # Save it
            machine_spec.save(action_handler)

            # ===========================
            # Ensure the machine is ready
            # ===========================

            # Construct the workflow
            workflow_name    = @driver_options[:vco_options][:workflows][:ready_machine][:name]
            workflow_options = {
              id:      @driver_options[:vco_options][:workflows][:ready_machine][:id],
              service: wf_service
            }
            workflow = VcoWorkflows::Workflow.new(workflow_name, workflow_options)

            # Set the parameters for the machine we want
            workflow.parameters = {
              'vmName' => machine_spec.reference['vm_uuid'],
              'vmUuid' => machine_spec.reference['vm_uuid']
            }

            # Execute the workflow and wait for the result
            workflow.execute
            wait_for_workflow(workflow.token)

            # If that was successful, build the machine object
            machine_for(action_handler, machine_spec, machine_options)
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
