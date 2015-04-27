require 'chef/provisioning/driver'
require 'chef/provisioning/version'
require 'chef/provisioning/machine/basic_machine'
require 'chef/provisioning/machine/unix_machine'
require 'chef/provisioning/machine/windows_machine'
require 'chef/provisioning/vco_driver/constants'
require 'chef/provisioning/vco_driver/version'
require 'chef/provisioning/transport/ssh'
require 'chef/provisioning/transport/winrm'
require 'vcoworkflows'

class Chef
  #
  module Provisioning
    #
    class Transport
      #
      class VmGuestTools < Chef::Provisioning::Transport

      end
    end
  end
end
