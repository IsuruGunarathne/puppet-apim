# ----------------------------------------------------------------------------
#  Copyright (c) 2021 WSO2, Inc. http://www.wso2.org
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
# ----------------------------------------------------------------------------

# Class apim::params
# This class includes all the necessary parameters.
class apim::params inherits apim_common::params {

  $start_script_template = 'bin/api-manager.sh'
  $jvmxms = '256m'
  $jvmxmx = '2048m'

  $template_list = [
    'repository/conf/deployment.toml'
  ]

  $file_list = [
    'repository/components/lib/postgresql-42.7.3.jar'
  ]

  $file_removelist = []

  $hostname = 'apim.wso2.com'

  # Override the CP-targeted defaults in apim_common::params — all services run on
  # this same host in the all-in-one topology.
  $event_listener_notification_endpoint = 'https://apim.wso2.com:${mgt.transport.https.port}/internal/data/v1/notify'
  $key_manager_server_url               = 'https://apim.wso2.com:${mgt.transport.https.port}${carbon.context}services/'
  $api_devportal_url                    = 'https://apim.wso2.com:${mgt.transport.https.port}/devportal'

  # Gateway endpoints published to API consumers via the DevPortal — must be reachable
  # from outside the VM, so they use the public hostname.
  $gateway_environments = [
    {
      type                                  => 'hybrid',
      name                                  => 'Default',
      gateway_type                          => 'Regular',
      provider                              => 'wso2',
      description                           => 'This is a hybrid gateway that handles both production and sandbox token traffic.',
      server_url                            => 'https://apim.wso2.com:${mgt.transport.https.port}${carbon.context}services/',
      ws_endpoint                           => 'ws://apim.wso2.com:9099',
      wss_endpoint                          => 'wss://apim.wso2.com:8099',
      http_endpoint                         => 'http://apim.wso2.com:8280',
      https_endpoint                        => 'https://apim.wso2.com:8243',
      websub_event_receiver_http_endpoint   => 'http://apim.wso2.com:9021',
      websub_event_receiver_https_endpoint  => 'https://apim.wso2.com:8021'
    }
  ]

  $oauth_configs_revoke_api_url        = 'https://apim.wso2.com:${https.nio.port}/revoke'
  $throttle_config_policy_deployer_url = 'https://apim.wso2.com:${mgt.transport.https.port}${carbon.context}services/'
}
