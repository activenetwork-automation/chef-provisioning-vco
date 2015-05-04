require 'chef/provisioning/transport'
require 'chef/log'
require 'vcoworkflows'

class Chef
  #
  module Provisioning
    #
    class Transport
      #
      class VmGuestTools < Chef::Provisioning::Transport
        #
        # ssh:   def initialize(host, username, ssh_options, options, global_config)
        # winrm: def initialize(endpoint, type, options, global_config)

        def initialize
          # TODO: do something
        end
      end
    end
  end
end
