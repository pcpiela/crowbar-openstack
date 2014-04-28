# Copyright 2011 Dell, Inc.
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

ha_enabled = node[:ceilometer][:ha][:server][:enabled]

if node[:ceilometer][:use_mongodb]
  include_recipe "ceilometer::mongodb" if !node[:ceilometer][:ha][:server][:enabled] || node[:ceilometer][:ha][:mongodb][:replica_set][:member]

  # need to wait for mongodb to start even if it's on a
  # different host (ceilometer services need it running)
  members = search(:node, "ceilometer_ha_mongodb_replica_set_member:true")
  # if we don't have HA enabled, then mongodb should be on the current host
  if members.empty?
    node_address = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
  else
    node_address = members.first.fqdn
  end
  ruby_block "wait for mongodb start" do
    block do
      require 'timeout'
      begin
        Timeout.timeout(60) do
          while ! ::Kernel.system("mongo #{node_address} --quiet < /dev/null &> /dev/null")
            Chef::Log.debug("mongodb still not reachable")
            sleep(2)
          end
        end
      rescue Timeout::Error
        Chef::Log.warn("mongodb on #{node_address} does not seem to be respondin g after trying for 1 minute")
      end
    end
  end
else
  db_settings = fetch_database_settings

  include_recipe "database::client"
  include_recipe "#{db_settings[:backend_name]}::client"
  include_recipe "#{db_settings[:backend_name]}::python-client"

  crowbar_pacemaker_sync_mark "wait-ceilometer_database"

  # Create the Ceilometer Database
  database "create #{node[:ceilometer][:db][:database]} database" do
      connection db_settings[:connection]
      database_name node[:ceilometer][:db][:database]
      provider db_settings[:provider]
      action :create
  end

  database_user "create ceilometer database user" do
      host '%'
      connection db_settings[:connection]
      username node[:ceilometer][:db][:user]
      password node[:ceilometer][:db][:password]
      provider db_settings[:user_provider]
      action :create
  end

  database_user "grant database access for ceilometer database user" do
      connection db_settings[:connection]
      username node[:ceilometer][:db][:user]
      password node[:ceilometer][:db][:password]
      database_name node[:ceilometer][:db][:database]
      host '%'
      privileges db_settings[:privs]
      provider db_settings[:user_provider]
      action :grant
  end
    
  crowbar_pacemaker_sync_mark "create-ceilometer_database"
end

unless node[:ceilometer][:use_gitrepo]
  case node["platform"]
    when "suse"
      package "openstack-ceilometer-collector"
      package "openstack-ceilometer-agent-notification"
      package "openstack-ceilometer-api"
      package "openstack-ceilometer-alarm-evaluator"
      package "openstack-ceilometer-alarm-notifier"
    when "centos", "redhat"
      package "openstack-ceilometer-common"
      package "openstack-ceilometer-collector"
      package "openstack-ceilometer-agent-notification"
      package "openstack-ceilometer-api"
      package "openstack-ceilometer-alarm"
      package "python-ceilometerclient"
    else
      package "python-ceilometerclient"
      package "ceilometer-common"
      package "ceilometer-collector"
      package "ceilometer-agent-notification"
      package "ceilometer-api"
      package "ceilometer-alarm-evaluator"
      package "ceilometer-alarm-notifier"
  end
else
  ceilometer_path = "/opt/ceilometer"

  venv_path = node[:ceilometer][:use_virtualenv] ? "#{ceilometer_path}/.venv" : nil
  venv_prefix = node[:ceilometer][:use_virtualenv] ? ". #{venv_path}/bin/activate &&" : nil
  puts "venv_path=#{venv_path}"
  puts "use_virtualenv=#{node[:ceilometer][:use_virtualenv]}"
  pfs_and_install_deps "ceilometer" do
    cookbook "ceilometer"
    cnode node
    virtualenv venv_path
    path ceilometer_path
    wrap_bins [ "ceilometer" ]
  end

  link_service "ceilometer-collector" do
    virtualenv venv_path
  end
  link_service "ceilometer-agent-notification" do
    virtualenv venv_path
  end
  link_service "ceilometer-api" do
    virtualenv venv_path
  end

  create_user_and_dirs("ceilometer")
  execute "cp_policy.json" do
    command "cp #{ceilometer_path}/etc/ceilometer/policy.json /etc/ceilometer"
    creates "/etc/ceilometer/policy.json"
  end
end

include_recipe "#{@cookbook_name}::common"

directory "/var/cache/ceilometer" do
  owner node[:ceilometer][:user]
  group "root"
  mode 00755
  action :create
end unless node.platform == "suse"

keystone_settings = KeystoneHelper.keystone_settings(node, @cookbook_name)

my_admin_host = CrowbarHelper.get_host_for_admin_url(node, ha_enabled)
my_public_host = CrowbarHelper.get_host_for_public_url(node, node[:ceilometer][:api][:protocol] == "https", ha_enabled)

crowbar_pacemaker_sync_mark "wait-ceilometer_db_sync"

execute "ceilometer-dbsync" do
  command "#{venv_prefix}ceilometer-dbsync"
  action :run
  user node[:ceilometer][:user]
  group node[:ceilometer][:group]
  # We only do the sync the first time, and only if we're not doing HA or if we
  # are the founder of the HA cluster (so that it's really only done once).
  only_if { !node[:ceilometer][:db_synced] && (!ha_enabled || CrowbarPacemakerHelper.is_cluster_founder?(node)) }
end

# We want to keep a note that we've done db_sync, so we don't do it again.
# If we were doing that outside a ruby_block, we would add the note in the
# compile phase, before the actual db_sync is done (which is wrong, since it
# could possibly not be reached in case of errors).
ruby_block "mark node for ceilometer db_sync" do
  block do
    node[:ceilometer][:db_synced] = true
    node.save
  end
  action :nothing
  subscribes :create, "execute[ceilometer-dbsync]", :immediately
end

crowbar_pacemaker_sync_mark "create-ceilometer_db_sync"

service "ceilometer-collector" do
  service_name node[:ceilometer][:collector][:service_name]
  supports :status => true, :restart => true, :start => true, :stop => true
  action [ :enable, :start ]
  subscribes :restart, resources("template[/etc/ceilometer/ceilometer.conf]")
  subscribes :restart, resources("template[/etc/ceilometer/pipeline.yaml]")
  provider Chef::Provider::CrowbarPacemakerService if ha_enabled
end

service "ceilometer-agent-notification" do
  service_name node[:ceilometer][:agent_notification][:service_name]
  supports :status => true, :restart => true, :start => true, :stop => true
  action [ :enable, :start ]
  subscribes :restart, resources("template[/etc/ceilometer/ceilometer.conf]")
  subscribes :restart, resources("template[/etc/ceilometer/pipeline.yaml]")
  provider Chef::Provider::CrowbarPacemakerService if ha_enabled
end

service "ceilometer-api" do
  service_name node[:ceilometer][:api][:service_name]
  supports :status => true, :restart => true, :start => true, :stop => true
  action [ :enable, :start ]
  subscribes :restart, resources("template[/etc/ceilometer/ceilometer.conf]")
  subscribes :restart, resources("template[/etc/ceilometer/pipeline.yaml]")
  provider Chef::Provider::CrowbarPacemakerService if ha_enabled
end

service "ceilometer-alarm-evaluator" do
  service_name node["ceilometer"]["alarm_evaluator"]["service_name"]
  supports :status => true, :restart => true, :start => true, :stop => true
  action [ :enable, :start ]
  subscribes :restart, resources("template[/etc/ceilometer/ceilometer.conf]")
  subscribes :restart, resources("template[/etc/ceilometer/pipeline.yaml]")
  provider Chef::Provider::CrowbarPacemakerService if ha_enabled
end

service "ceilometer-alarm-notifier" do
  service_name node["ceilometer"]["alarm_notifier"]["service_name"]
  supports :status => true, :restart => true, :start => true, :stop => true
  action [ :enable, :start ]
  subscribes :restart, resources("template[/etc/ceilometer/ceilometer.conf]")
  subscribes :restart, resources("template[/etc/ceilometer/pipeline.yaml]")
  provider Chef::Provider::CrowbarPacemakerService if ha_enabled
end

if ha_enabled
  log "HA support for ceilometer is enabled"
  include_recipe "ceilometer::server_ha"
else
  log "HA support for ceilometer is disabled"
end

crowbar_pacemaker_sync_mark "wait-ceilometer_register"

keystone_register "ceilometer wakeup keystone" do
  protocol keystone_settings['protocol']
  host keystone_settings['internal_url_host']
  port keystone_settings['admin_port']
  token keystone_settings['admin_token']
  action :wakeup
end

keystone_register "register ceilometer user" do
  protocol keystone_settings['protocol']
  host keystone_settings['internal_url_host']
  port keystone_settings['admin_port']
  token keystone_settings['admin_token']
  user_name keystone_settings['service_user']
  user_password keystone_settings['service_password']
  tenant_name keystone_settings['service_tenant']
  action :add_user
end

keystone_register "give ceilometer user access" do
  protocol keystone_settings['protocol']
  host keystone_settings['internal_url_host']
  port keystone_settings['admin_port']
  token keystone_settings['admin_token']
  user_name keystone_settings['service_user']
  tenant_name keystone_settings['service_tenant']
  role_name "admin"
  action :add_access
end

env_filter = " AND ceilometer_config_environment:#{node[:ceilometer][:config][:environment]}"
swift_middlewares = search(:node, "roles:ceilometer-swift-proxy-middleware#{env_filter}") || []
unless swift_middlewares.empty?
  keystone_register "give ceilometer user ResellerAdmin role" do
    protocol keystone_settings['protocol']
    host keystone_settings['internal_url_host']
    port keystone_settings['admin_port']
    token keystone_settings['admin_token']
    user_name keystone_settings['service_user']
    tenant_name keystone_settings['service_tenant']
    role_name "ResellerAdmin"
    action :add_access
  end
end

# Create ceilometer service
keystone_register "register ceilometer service" do
  protocol keystone_settings['protocol']
  host keystone_settings['internal_url_host']
  port keystone_settings['admin_port']
  token keystone_settings['admin_token']
  service_name "ceilometer"
  service_type "metering"
  service_description "Openstack Telemetry Service"
  action :add_service
end

keystone_register "register ceilometer endpoint" do
  protocol keystone_settings['protocol']
  host keystone_settings['internal_url_host']
  port keystone_settings['admin_port']
  token keystone_settings['admin_token']
  endpoint_service "ceilometer"
  endpoint_region "RegionOne"
  endpoint_publicURL "#{node[:ceilometer][:api][:protocol]}://#{my_public_host}:#{node[:ceilometer][:api][:port]}"
  endpoint_adminURL "#{node[:ceilometer][:api][:protocol]}://#{my_admin_host}:#{node[:ceilometer][:api][:port]}"
  endpoint_internalURL "#{node[:ceilometer][:api][:protocol]}://#{my_admin_host}:#{node[:ceilometer][:api][:port]}"
#  endpoint_global true
#  endpoint_enabled true
  action :add_endpoint_template
end

crowbar_pacemaker_sync_mark "create-ceilometer_register"

node.save
