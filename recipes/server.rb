# encoding: utf-8
#
# Cookbook Name:: ssh-hardening
# Recipe:: server.rb
#
# Copyright 2012, Dominik Richter
# Copyright 2014, Deutsche Telekom AG
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# default attributes
# We can not set this kind of defaults in the attribute files
# as we react on value of other attributes
# https://github.com/dev-sec/chef-ssh-hardening/issues/140#issuecomment-267779720
node.default['ssh-hardening']['ssh']['server']['listen_to'] =
  if node['ssh-hardening']['network']['ipv6']['enable']
    ['0.0.0.0', '::']
  else
    ['0.0.0.0']
  end

# installs package name
package 'openssh-server' do
  package_name node['ssh-hardening']['sshserver']['package']
end

# Handle addional SELinux policy on RHEL/Fedora for different UsePAM options
if %w(fedora rhel).include?(node['platform_family'])
  policy_dir = ::File.join(Chef::Config[:file_cache_path], cookbook_name.to_s)
  policy_file = ::File.join(policy_dir, 'ssh_password.te')
  module_file = ::File.join(policy_dir, 'ssh_password.mod')
  package_file = ::File.join(policy_dir, 'ssh_password.pp')

  package 'policycoreutils-python'
  # on fedora we need an addtional package for semodule_package
  package 'policycoreutils-python-utils' if node['platform_family'] == 'fedora'

  if node['ssh-hardening']['ssh']['server']['use_pam']
    # UsePAM yes: disable and remove the additional SELinux policy

    execute 'remove selinux policy' do
      command 'semodule -r ssh_password'
      only_if 'getenforce | grep -vq Disabled && semodule -l | grep -q ssh_password'
    end
  else
    # UsePAM no: enable and install the additional SELinux policy

    directory policy_dir

    cookbook_file policy_file do
      source 'ssh_password.te'
    end

    bash 'build selinux package and install it' do
      code <<-EOC
        checkmodule -M -m -o #{module_file} #{policy_file}
        semodule_package -o #{package_file} -m #{module_file}
        semodule -i #{package_file}
      EOC
      not_if 'getenforce | grep -q Disabled || semodule -l | grep -q ssh_password'
    end
  end
end

# defines the sshd service
service 'sshd' do
  # use upstart for ubuntu, otherwise chef uses init
  # @see http://docs.opscode.com/resource_service.html#providers
  case node['platform']
  when 'ubuntu'
    if node['platform_version'].to_f >= 15.04
      provider Chef::Provider::Service::Systemd
    elsif node['platform_version'].to_f >= 12.04
      provider Chef::Provider::Service::Upstart
    end
  end
  service_name node['ssh-hardening']['sshserver']['service_name']
  supports value_for_platform(
    'centos' => { 'default' => [:restart, :reload, :status] },
    'redhat' => { 'default' => [:restart, :reload, :status] },
    'fedora' => { 'default' => [:restart, :reload, :status] },
    'scientific' => { 'default' => [:restart, :reload, :status] },
    'arch' => { 'default' => [:restart] },
    'debian' => { 'default' => [:restart, :reload, :status] },
    'ubuntu' => {
      '8.04' => [:restart, :reload],
      'default' => [:restart, :reload, :status]
    },
    'default' => { 'default' => [:restart, :reload] }
  )
  action [:enable, :start]
end

directory 'openssh-server ssh directory /etc/ssh' do
  path '/etc/ssh'
  mode '0755'
  owner 'root'
  group 'root'
end

template '/etc/ssh/sshd_config' do
  source 'opensshd.conf.erb'
  mode '0600'
  owner 'root'
  group 'root'
  variables(
    mac:    node['ssh-hardening']['ssh']['server']['mac']    || DevSec::Ssh.get_server_macs(node['ssh-hardening']['ssh']['server']['weak_hmac']),
    kex:    node['ssh-hardening']['ssh']['server']['kex']    || DevSec::Ssh.get_server_kexs(node['ssh-hardening']['ssh']['server']['weak_kex']),
    cipher: node['ssh-hardening']['ssh']['server']['cipher'] || DevSec::Ssh.get_server_ciphers(node['ssh-hardening']['ssh']['server']['cbc_required']),
    use_priv_sep: node['ssh-hardening']['ssh']['use_privilege_separation'] || DevSec::Ssh.get_server_privilege_separarion
  )
  notifies :restart, 'service[sshd]'
end

execute 'unlock root account if it is locked' do
  command "sed 's/^root:\!/root:*/' /etc/shadow -i"
  only_if { node['ssh-hardening']['ssh']['allow_root_with_key'] }
end
