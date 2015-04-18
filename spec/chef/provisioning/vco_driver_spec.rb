require 'spec_helper'

describe Chef::Provisioning::VcoDriver do
  it 'has a version number' do
    expect(Chef::Provisioning::VcoDriver::VERSION).not_to be nil
  end

  it 'does nothing useful' do
    expect(true).to eq(true)
  end
end
