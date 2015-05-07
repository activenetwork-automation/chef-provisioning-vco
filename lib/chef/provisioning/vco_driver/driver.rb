require 'chef/provisioning/driver'
require 'chef/provisioning/version'
require 'chef/provisioning/machine/basic_machine'
require 'chef/provisioning/machine/unix_machine'
require 'chef/provisioning/machine/windows_machine'
require 'chef/provisioning/vco_driver/constants'
require 'chef/provisioning/vco_driver/version'
require 'chef/provisioning/convergence_strategy/install_cached'
require 'chef/provisioning/convergence_strategy/install_sh'
require 'chef/provisioning/convergence_strategy/install_msi'
require 'chef/provisioning/convergence_strategy/no_converge'
require 'chef/provisioning/transport/ssh'
require 'chef/provisioning/transport/winrm'
require 'vcoworkflows'

# rubocop:disable ClassLength

#
class Chef
  #
  module Provisioning
    #
    module VcoDriver
      #
      class Driver < Chef::Provisioning::Driver
        # Pull in constants
        include Chef::Provisioning::VcoDriver::Constants

        # vRA Tenant name
        attr_reader :tenant

        # vRA Tenant Business Group name
        attr_reader :business_unit

        # Chef Provisioning Driver Options
        attr_reader :driver_options

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

          Chef::Log.info "Initializing vco_driver version #{VERSION}, driver_url '#{driver_url}'"

          _, @tenant, @business_unit = driver_url.split(/:/)

          Chef::Log.debug "vCO driver: tenant: '#{@tenant}'"
          Chef::Log.debug "vCO driver: business unit: '#{@business_unit}'"

          Chef::Log.debug "vCO driver: given config:\n#{config.to_yaml}"

          # Merge driver option defaults with given options.
          Chef::Log.debug "vCO driver: default driver options:\n#{DEFAULT_DRIVER_OPTIONS.to_yaml}"
          Chef::Log.debug "vCO driver: given driver options:\n#{config[:driver_options].to_yaml}"
          Chef::Log.debug 'vCO driver: extracting and merging vco_options...'
          vco_options = DEFAULT_DRIVER_OPTIONS[:vco_options].merge(config[:driver_options][:vco_options])
          Chef::Log.debug 'vCO driver: merging base driver options...'
          @driver_options = DEFAULT_DRIVER_OPTIONS.merge(config[:driver_options])
          Chef::Log.debug 'vCO driver: re-merging vco_options...'
          @driver_options[:vco_options] = vco_options
          Chef::Log.debug "vCO driver: options set to: \n#{@driver_options.to_yaml}"

          # Set max_wait from the driver options
          @max_wait      = @driver_options[:vco_options][:max_wait]
          @wait_interval = @driver_options[:vco_options][:wait_interval]

          Chef::Log.debug "vCO driver: max_wait set to #{@max_wait} seconds."
          Chef::Log.debug "vCO driver: wait_interval set to #{@wait_interval} seconds."
        end

        def self.canonicalize_url(driver_url, config)
          [driver_url, config]
        end

        # rubocop:disable LineLength, MethodLength, BlockNesting

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
          Chef::Log.debug "vCO driver: Creating instance with machine options #{machine_options}"

          # If we expect a machine to be here, and it's not currently building,
          # see if it actually exists or force a new allocation.
          if machine_spec.reference && !machine_building?(machine_spec, machine_options)
            if instance_for(machine_spec, machine_options).nil?
              # See if the provisioning process succeeded (which will seed the
              # 'vm_name' and 'vm_uuid' keys into machine_spec).
              begin
                wait_for_machine(machine_spec, machine_options)
              rescue => exception
                # If the exception is anything other than "workflow failed",
                # re-raise. Simply eat the "workflow failed" exception.
                # Keep Calm and Provision On.
                raise exception unless exception.to_s.match(/Workflow failed/i)
              end
              # Machine failed to build entirely, try again.
              Chef::Log.info "Machine #{machine_spec.name} does not exist in provider, will re-create."
              machine_spec.reference = nil
            end
          end

          # If we don't need to recreate the instance, stop here.
          return machine_spec if machine_spec.reference

          action_handler.perform_action "Create machine #{machine_spec.name} with template #{machine_options[:image]}, tenant #{@tenant}, business unit #{@business_unit}\n" do
            bootstrap_options = bootstrap_options_for(action_handler, machine_spec, machine_options)

            # Set up the parameters for the :allocate_machine workflow.
            parameters = {
              'nodename'          => machine_spec.name,
              'tenant'            => @tenant,
              'businessUnit'      => @business_unit,
              'reservationPolicy' => bootstrap_options[:reservation_policy],
              'environment'       => bootstrap_options[:environment],
              'onBehalfOf'        => bootstrap_options[:on_behalf_of],
              'location'          => bootstrap_options[:location],
              'component'         => bootstrap_options[:component],
              'coreCount'         => bootstrap_options[:cpu],
              'ramMB'             => bootstrap_options[:ram],
              'image'             => bootstrap_options[:image]
            }
            execution = execute_workflow(:allocate_machine, parameters)

            # Create our reference data
            machine_spec.reference = {
              'driver_url'     => driver_url,
              'driver_version' => Chef::Provisioning::VcoDriver::VERSION,
              'allocated_at'   => Time.now.utc.to_s,
              'host_node'      => action_handler.host_node,
              'vco_url'        => @driver_options[:vco_options][:url],
              'workflow_name'  => execution.name,
              'workflow_id'    => execution.workflow_id,
              'execution_id'   => execution.id,
              'cpu'            => bootstrap_options[:cpu],
              'ram'            => bootstrap_options[:ram],
              'image'          => bootstrap_options[:image]
            }

            # Some options that may or may not be present...
            machine_spec.reference['ssh_username'] = machine_options[:ssh_username] if machine_options.key?(:ssh_username)
            machine_spec.reference['sudo']         = machine_options[:sudo] if machine_options.key?(:sudo)
            machine_spec.reference['is_windows']   = machine_options[:is_windows] if machine_options[:is_windows]
            machine_spec.reference['key_name'] = bootstrap_options[:key_name] if bootstrap_options[:key_name]
            %w(is_windows ssh_username sudo use_private_ip_for_ssh ssh_gateway).each do |key|
              machine_spec.reference[key] = machine_options[key.to_sym] if machine_options[key.to_sym]
            end
          end
        end
        # rubocop:enable LineLength, MethodLength, BlockNesting

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
          Chef::Log.debug "vCO driver: Ready machine with machine_spec reference #{machine_spec.reference}"

          instance = instance_for(machine_spec, machine_options)

          # If we couldn't already get an instance, and it's still building,
          # wait for the build to complete.
          if !instance && machine_building?(machine_spec, machine_options)
            action_handler.perform_action("Waiting for machine #{machine_spec.name} to build...") do
              wait_for_machine(machine_spec, machine_options)
            end
          end

          # If we had to wait for it to build, get the instance
          instance ||= instance_for(machine_spec, machine_options)
          if instance && instance[:guest_state].nil?
            Chef::Log.warn 'vCO driver: Got instance with nil guestState!'
          end

          # Make sure the VM is powered on and available
          unless instance[:guest_state].eql?('running')
            Chef::Log.debug "vCO driver: Machine not running(?): power = #{instance['powerState']}, guest state = #{instance['guestState']}"
            start_machine(action_handler, machine_spec, machine_options, instance)
          end

          Chef::Log.debug "vCO driver: Creating Machine object for instance #{machine_spec.name}"
          machine = machine_for(machine_spec, machine_options, instance)

          Chef::Log.debug "vCO driver: Got machine for #{machine_spec.name}: #{machine}"
          machine
        end

        # Connect to a machine without allocating or readying it.  This method will
        # NOT make any changes to anything, or attempt to wait.
        #
        # @param [Chef::Provisioning::ManagedEntry] machine_spec ManagedEntry representing this machine.
        # @param [Hash] machine_options
        # @return [Machine] A machine object pointing at the machine, allowing useful actions like setup,
        # converge, execute, file and directory.
        #
        def connect_to_machine(machine_spec, machine_options, instance = nil)
          machine_for(machine_spec, machine_options, instance)
        end

        # Delete the given machine --  destroy the machine,
        # returning things to the state before allocate_machine was called.
        #
        # @param [Chef::Provisioning::ActionHandler] action_handler The action_handler object that is calling this method
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        def destroy_machine(action_handler, machine_spec, machine_options, instance = nil)
          instance ||= instance_for(machine_spec, machine_options)

          if instance.nil?
            Chef::Log.warn "vCO driver: Instance #{machine_spec.name} does not seem to exist, nothing to destroy."
            return
          end

          action_handler.perform_action "Destroy #{machine_spec.name} tenant #{@tenant}, business unit #{@business_unit}\n" do
            Chef::Log.debug "vCO driver: Destroying instance #{machine_spec.name}..."

            # Execute the :destroy_machine workflow
            execution = execute_workflow(:destroy_machine,
                                         {
                                           'vmName' => machine_spec.reference['vm_name'],
                                           'vmUuid' => machine_spec.reference['vm_uuid']
                                         },
                                         wait: true)
            raise "Destroy machine #{machine_spec.name} failed!" if execution.state.match(/failed/i)
          end
        end

        # Stop the machine.
        #
        # @param [Chef::Provisioning::ActionHandler] action_handler The action_handler object that is calling this method
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        def stop_machine(action_handler, machine_spec, machine_options, instance = nil)
          instance ||= instance_for(machine_spec, machine_options)

          if instance.nil?
            Chef::Log.debug "vCO driver: Instance #{machine_spec.name} does not seem to exist, nothing to stop."
            return
          end

          action_handler.perform_action "Stopping machine #{machine_spec.name}\n" do
            Chef::Log.debug "vCO driver: Stopping machine #{machine_spec.name}"

            # Execute the :stop_machine workflow
            execution = execute_workflow(:stop_machine,
                                         {
                                           'vmName' => machine_spec.reference['vm_name'],
                                           'vmUuid' => machine_spec.reference['vm_uuid']
                                         },
                                         wait: true)
            raise "Stop machine #{machine_spec.name} failed!" if execution.state.match(/failed/i)
          end
        end

        # Start the machine
        #
        # @param [Chef::Provisioning::ActionHandler] action_handler The action_handler object that is calling this method
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        def start_machine(action_handler, machine_spec, machine_options, instance)
          instance ||= instance_for(machine_spec, machine_options)

          # No point in starting a machine that's already running...
          if instance[:guest_state].eql?('running')
            Chef::Log.debug "vCO driver: Instance #{machine_spec.name} is already running. Nothing to do."
            return
          end

          action_handler.perform_action "Starting machine #{machine_spec.name}...\n" do
            Chef::Log.debug "vCO driver: Starting machine with machine_spec reference: #{machine_spec.reference}"

            # Execute the :start_machine workflow
            execution = execute_workflow(:start_machine,
                                         {
                                           'vmName' => machine_spec.reference['vm_name'],
                                           'vmUuid' => machine_spec.reference['vm_uuid']
                                         },
                                         wait: true)
            raise "Start machine #{machine_spec.name} failed!" if execution.state.match(/failed/i)
          end
        end

        def bootstrap_options_for(action_handler, machine_spec, machine_options)
          _ = action_handler
          _ = machine_spec
          bootstrap_options = (machine_options[:bootstrap_options] || {}).to_h.dup
          # image_id = bootstrap_options[:image_id] || machine_options[:image_id] || default_ami_for_region(aws_config.region)
          # bootstrap_options[:image_id] = image_id
          # if !bootstrap_options[:key_name]
          #   Chef::Log.debug('No key specified, generating a default one...')
          #   bootstrap_options[:key_name] = default_aws_keypair(action_handler, machine_spec)
          # end
          image = bootstrap_options[:image] || machine_options[:image] || nil
          bootstrap_options[:image] = image

          # if machine_options[:is_windows]
          #   Chef::Log.debug "Setting WinRM userdata..."
          #   bootstrap_options[:user_data] = user_data
          # else
          #   Chef::Log.debug "Non-windows, not setting userdata"
          # end

          # bootstrap_options = AWSResource.lookup_options(bootstrap_options, managed_entry_store: machine_spec.managed_entry_store, driver: self)
          # Chef::Log.debug "AWS Bootstrap options: #{bootstrap_options.inspect}"
          bootstrap_options
        end

        # Create a machine object
        #
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        # @param [Hash] instance An "instance" hash describing live data about the VM
        # @return [Chef::Provisioning::Machine]
        def machine_for(machine_spec, machine_options, instance = nil)
          instance ||= instance_for(machine_spec, machine_options)

          raise "Instance for node #{machine_spec.name} has not been created!" unless instance

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
          _ = machine_options

          instance = nil

          if machine_spec.reference
            if machine_spec.reference.key?('driver_url') && machine_spec.reference['driver_url'] != driver_url
              raise "Switching a machine's driver from #{machine_spec.reference['driver_url']} to #{driver_url} is not currently supported!  Use machine :destroy and then re-create the machine on the new driver."
            end

            # If we have the necessary machine_spec reference items, get the instance data
            Chef::Log.debug "vCO driver: Finding instance for #{machine_spec.name}..."

            if machine_spec.reference.key?('vm_name') && machine_spec.reference.key?('vm_uuid')
              # Execute the :get_machine_info workflow
              execution = execute_workflow(:get_machine_info,
                                           {
                                             'vmName' => machine_spec.reference['vm_name'],
                                             'vmUuid' => machine_spec.reference['vm_uuid']
                                           },
                                           wait: true)

              unless execution.state.match(/failed/i)
                instance                   = {}
                instance[:guest_state]     = execution.output_parameters['guestState'].value
                instance[:power_state]     = execution.output_parameters['powerState'].value
                instance[:host_name]       = execution.output_parameters.key?('hostName') ? execution.output_parameters['hostName'].value : nil
                instance[:ip_address]      = execution.output_parameters.key?('ipAddress') ? execution.output_parameters['ipAddress'].value : nil
                instance[:vm_host]         = execution.output_parameters.key?('vmHost') ? execution.output_parameters['vmHost'].value : nil
                instance[:boot_time]       = execution.output_parameters.key?('bootTime') ? execution.output_parameters['bootTime'].value : nil
                instance[:clean_power_off] = execution.output_parameters.key?('cleanPowerOff') ? execution.output_parameters['cleanPowerOff'].value : nil
                instance[:online_standby]  = execution.output_parameters.key?('onlineStandBy') ? execution.output_parameters['onlineStandBy'].value : nil
              end
              Chef::Log.debug "vCO driver: Retrieved instance data:\n#{instance.to_yaml}"
            end
          end

          Chef::Log.debug "vCO driver: Failed to find instance for #{machine_spec.name} (instance = nil)" unless instance

          instance
        end

        # Get an appropriate transport for the machine
        # Stolen gratuitously from Chef::Provisioning::AwsDriver
        #
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        # @return [Chef::Provisioning::Transport::SSH]
        def transport_for(machine_spec, machine_options, instance)
          # if machine_options.key?(:transport) && machine_options[:transport].eql?(:vmtools)
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
          ssh_options = ssh_options_for(machine_spec, machine_options, instance)
          username = machine_spec.reference['ssh_username'] || machine_options[:ssh_username] || default_ssh_username
          if machine_options.key?(:ssh_username) && machine_options[:ssh_username] != machine_spec.reference['ssh_username']
            Chef::Log.warn("Server #{machine_spec.name} was created with SSH username #{machine_spec.reference['ssh_username']} and machine_options specifies username #{machine_options[:ssh_username]}.  Using #{machine_spec.reference['ssh_username']}.  Please edit the node and change the chef_provisioning.reference.ssh_username attribute if you want to change it.")
          end
          options = {}
          if machine_spec.reference[:sudo] || (!machine_spec.reference.key?(:sudo) && username != 'root')
            options[:prefix] = 'sudo '
          end

          # remote_host = determine_remote_host(machine_spec, instance)
          remote_host = instance[:ip_address]

          # Enable pty by default
          options[:ssh_pty_enable] = true
          options[:ssh_gateway] = machine_spec.reference['ssh_gateway'] if machine_spec.reference.key?('ssh_gateway')

          Chef::Provisioning::Transport::SSH.new(remote_host, username, ssh_options, options, config)
        end

        # Create a WinRM Transport
        # Stolen gratuitously from Chef::Provisioning::AwsDriver
        # TODO: Actually implment this...
        #
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        # @return [Chef::Provisioning::Transport::WinRM]
        def create_winrm_transport(machine_spec, machine_options, instance)
          _ = machine_spec
          _ = machine_options
          _ = instance
          # # remote_host = determine_remote_host(machine_spec, instance)
          # remote_host = instance[:ip_address]
          #
          # port = machine_spec.reference['winrm_port'] || 5985
          # endpoint = "http://#{remote_host}:#{port}/wsman"
          # type = :plaintext
          # pem_bytes = get_private_key(instance.key_name)
          # encrypted_admin_password = wait_for_admin_password(machine_spec)
          #
          # decoded = Base64.decode64(encrypted_admin_password)
          # private_key = OpenSSL::PKey::RSA.new(pem_bytes)
          # decrypted_password = private_key.private_decrypt decoded
          #
          # winrm_options = {
          #   :user => machine_spec.reference['winrm_username'] || 'Administrator',
          #   :pass => decrypted_password,
          #   :disable_sspi => true,
          #   :basic_auth_only => true
          # }
          #
          # Chef::Provisioning::Transport::WinRM.new("#{endpoint}", type, winrm_options, {})
        end

        # Stolen gratuitously from Chef::Provisioning::AwsDriver
        # TODO: Actually implment this...
        #
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        # @return [Chef::Provisioning::Transport::WinRM]
        def ssh_options_for(machine_spec, machine_options, instance)
          result = {
            # TODO create a user known hosts file
            #          :user_known_hosts_file => vagrant_ssh_config['UserKnownHostsFile'],
            #          :paranoid => true,
            :auth_methods => [ 'publickey' ],
            :keys_only => true
          }.merge(machine_options[:ssh_options] || {})

          # If we're not flat-out pointed at key files to use for SSH, figure
          # out the key data from :bootstrap_options (aws-ish)
          if machine_options[:bootstrap_options] && machine_options[:bootstrap_options][:key_path]
            result[:key_data] = [ IO.read(machine_options[:bootstrap_options][:key_path]) ]
          else
            unless machine_options[:ssh_options].key?(:keys)
              # TODO make a way to suggest other keys to try ...
              raise "No key found to connect to #{machine_spec.name} (#{machine_spec.reference.inspect})!"
            end
          end
          result
        end

        # Stolen gratuitously from Chef::Provisioning::AwsDriver
        # TODO: Actually implment this...
        #
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        # @return [Chef::Provisioning::Transport::WinRM]
        def convergence_strategy_for(machine_spec, machine_options)
          # Tell Ohai that this is an EC2 instance so that it runs the EC2 plugin
          # convergence_options = Cheffish::MergedConfig.new(
          #   machine_options[:convergence_options] || {},
          #   ohai_hints: { 'ec2' => '' })
          convergence_options = Cheffish::MergedConfig.new(machine_options[:convergence_options] || {},
                                                           ohai_hints: {})

          # Defaults
          unless machine_spec.reference
            return Chef::Provisioning::ConvergenceStrategy::NoConverge.new(convergence_options, config)
          end

          if machine_spec.reference['is_windows']
            Chef::Provisioning::ConvergenceStrategy::InstallMsi.new(convergence_options, config)
          elsif machine_options[:cached_installer] == true
            Chef::Provisioning::ConvergenceStrategy::InstallCached.new(convergence_options, config)
          else
            Chef::Provisioning::ConvergenceStrategy::InstallSh.new(convergence_options, config)
          end
        end

        # Private methods start here

        private

        # Create a workflow service object by using the defined driver options
        #
        # @param [Hash] driver_options
        # @return [VcoWorkflows::WorkflowService]
        def workflow_service_for(driver_options = {})
          # Chef::Log.debug "vCO driver: Generating workflow service for #{driver_options[:vco_options][:url]}"
          vcosession = VcoWorkflows::VcoSession.new(driver_options[:vco_options][:url],
                                                    user:       driver_options[:vco_options][:username],
                                                    password:   driver_options[:vco_options][:password],
                                                    verify_ssl: driver_options[:vco_options][:verify_ssl])
          VcoWorkflows::WorkflowService.new(vcosession)
        end

        # Handle workflow execution
        #
        # @param [Symbol] workflow The workflow symbol denoting which workflow to execute.
        #  Valid symbols are:
        #  - :allocate_machine
        #  - :start_machine
        #  - :stop_machine
        #  - :destroy_machine
        #  - :get_machine_info
        # @param [Hash] parameters Parameters to set for the workflow
        # @param [Boolean] wait Whether to wait for the execution to complete or not
        # @return [VcoWorkflows::WorkflowToken] Workflow execution results
        def execute_workflow(workflow_tag, parameters = {}, wait: false)

          # Shorthand to the workflows hash in @driver_options
          workflows = @driver_options[:vco_options][:workflows]

          # Bail if we don't know about the requested workflow.
          raise "Attempted to execute non-existant workflow: #{workflow_tag}!" unless workflows.key?(workflow_tag)

          wf_name = workflows[workflow_tag][:name]
          wf_id   = workflows[workflow_tag][:id]

          Chef::Log.debug "vCO driver: processing workflow #{wf_name}, id: #{wf_id}"
          Chef::Log.debug "vCO driver: #{wf_name} parameters: #{parameters}"
          Chef::Log.debug "vCO driver: #{wf_name} wait: #{wait}"

          Chef::Log.debug "vCO driver: retrieving workflow #{wf_name}, #{wf_id} from Orchestrator..."
          service = workflow_service_for(@driver_options)
          workflow = VcoWorkflows::Workflow.new(wf_name, id: wf_id, service: service)

          workflow.parameters = parameters

          Chef::Log.debug "vCO driver: Executing workflow #{wf_name}, #{wf_id} ..."
          workflow.execute

          # Get the token
          execution = workflow.token

          # No need to wait if the workflow is already "dead" (failed, completed, etc...)
          if wait && execution.alive?
            Chef::Log.debug "vCO driver: waiting for completion of #{wf_name} execution #{execution.id}"
            execution = wait_for_workflow(execution)
          end

          Chef::Log.debug "vCO driver: returning #{wf_name} execution results:\n#{execution}"
          execution
        end

        # Wait for a workflow execution to complete
        #
        # @param [VcoWorkflows::WorkflowToken] execution WorkflowToken for the execution you are waiting for
        # @return [VcoWorkflows::WorkflowTokwn] Updated token
        def wait_for_workflow(execution)
          Chef::Log.debug "vCO driver: Checking status of #{execution.name} execution #{execution.id}"
          start_wait = Time.now
          while execution.alive? && (Time.now - start_wait < @max_wait)
            sleep @wait_interval
            execution = get_workflow_execution(execution.workflow_id, execution.id)
            if execution.alive?
              Chef::Log.debug "vCO driver: #{execution.name} execution #{execution.id} still running (state: #{execution.state}; waited #{Time.now - start_wait}s so far)"
            end
          end

          # If execution state is still in something "still running", bail on wait timeout.
          # Note: when execution is completed execution.alive? will be false.
          raise "Workflow wait timeout for #{machine_spec.name}" if execution.alive?

          # Return the updated token
          execution
        end

        # Get a workflow token for a known execution
        #
        # @param [String] workflow_id UUID of the workflow
        # @param [String] execution_id UUID of the execution
        # @return [VcoWorkflows::WorkflowToken]
        def get_workflow_execution(workflow_id, execution_id)
          VcoWorkflows::WorkflowToken.new(workflow_service_for(@driver_options), workflow_id, execution_id)
        end

        # Wait for a machine that is building, and when the build is complete,
        # take the VM Name and UUID of the resulting VM and store it in the
        # machine_spec.reference
        #
        # @param [Chef::Provisioning::ManagedEntry] machine_spec A machine specification representing this machine.
        # @param [Hash] machine_options A set of options representing the desired state of the machine
        def wait_for_machine(machine_spec, machine_options)
          _ = machine_options
          # Get the WorkflowToken for our execution, so we can get some additional
          # information to locate our VM. If the VM request isn't complete yet, we need to
          # hang around and wait for it to complete. Stop waiting when we hit our max_wait
          # timeout.
          Chef::Log.debug "vCO driver: Waiting for #{machine_spec.name} to complete provisioning..."
          execution = wait_for_workflow(get_workflow_execution(machine_spec.reference['workflow_id'],
                                                               machine_spec.reference['execution_id']))

          # If this workflow execution failed, it means the machine failed
          # to successfully provision. Raise an exception.
          raise "Workflow failed for #{machine_spec.name}!" if execution.state.match(/failed/i)

          # If execution state is still in something "still running", bail on wait timeout.
          # Note: when execution is completed execution.alive? will be false.
          raise "Workflow wait timeout for #{machine_spec.name}" if execution.alive?

          Chef::Log.debug "vCO driver: Provisioning for #{machine_spec.name} appears to have succeeded."
          # Get the vm name and uuid from the workflow output parameters.
          # These are arrays, but should only have a single element for our VM.
          vm_uuids = execution.output_parameters['provisionedVmUuids'].value
          vm_names = execution.output_parameters['provisionedVmNames'].value

          # Sanity check, we should have the same number of names to uuids (1:1)
          if vm_uuids.length != vm_names.length
            raise "Provisioned VM UUID count doesn't match provisioned VM Name count."
          end

          # And we should only have a single VM in the result set
          if vm_uuids.length > 1 || vm_names.length > 1
            raise "#{machine_spec.name} provisioned by #{execution.name} request #{execution.id} resulted in multiple VMs!"
          end

          # Everything looks good, let's grab and save the name and uuid for future reference.
          # We need to add the VM uuid because there's a possibility that the execution_id
          # we saved in allocate_machine could go away if something on the Orchestrator
          # server changes, and we don't want that to trigger a re-allocation for something
          # that already exists.
          Chef::Log.debug "vCO driver: Provisioned #{machine_spec.name}, vm_name #{vm_names.first}, vm_uuid #{vm_uuids.first}"
          machine_spec.reference['vm_uuid'] = vm_uuids.first
          machine_spec.reference['vm_name'] = vm_names.first
        end

        def machine_building?(machine_spec, machine_options)
          Chef::Log.debug "vCO driver: Determining if machine #{machine_spec.name} is still building..."
          is_building = false
          if machine_spec.reference.key?('workflow_id') && machine_spec.reference.key?('execution_id')
            if instance_for(machine_spec, machine_options).nil?
              execution = get_workflow_execution(machine_spec.reference['workflow_id'],
                                             machine_spec.reference['execution_id'])
              is_building = execution.alive?
            end
          end
          is_building
        end

        def default_ssh_username
          'root'
        end
      end
    end
  end
end
