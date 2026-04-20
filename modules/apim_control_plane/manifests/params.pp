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

# Class apim_control_plane::params
# This class includes all the necessary parameters.
class apim_control_plane::params inherits apim_common::params {

  $start_script_template = 'bin/api-cp.sh'
  $jvmxms = '256m'
  $jvmxmx = '2048m'

  $template_list = [
    'repository/conf/deployment.toml',
  ]

  $file_list = [
    'repository/components/lib/postgresql-42.7.3.jar'
  ]

  $file_removelist = []

  $ports_offset = 0
  $hostname = 'cp.wso2.com'

  # PostgreSQL database config
  $wso2am_db_url              = 'jdbc:postgresql://db.wso2.com:5432/apimgt'
  $wso2am_db_username         = 'apimuser'
  $wso2am_db_password         = 'apimpassword'
  $wso2am_db_type             = 'postgre'
  $wso2am_db_validation_query = 'SELECT 1'

  $wso2shared_db_url              = 'jdbc:postgresql://db.wso2.com:5432/shareddb'
  $wso2shared_db_username         = 'apimuser'
  $wso2shared_db_password         = 'apimpassword'
  $wso2shared_db_type             = 'postgre'
  $wso2shared_db_validation_query = 'SELECT 1'

  # Gateway environment pointing to GW node
  $gateway_environments = [
    {
      type                                  => 'hybrid',
      name                                  => 'Default',
      gateway_type                          => 'Regular',
      provider                              => 'wso2',
      description                           => 'This is a hybrid gateway that handles both production and sandbox token traffic.',
      server_url                            => 'https://gw.wso2.com:${mgt.transport.https.port}${carbon.context}services/',
      ws_endpoint                           => 'ws://gw.wso2.com:9099',
      wss_endpoint                          => 'wss://gw.wso2.com:8099',
      http_endpoint                         => 'http://gw.wso2.com:8280',
      https_endpoint                        => 'https://gw.wso2.com:8243',
      websub_event_receiver_http_endpoint   => 'http://gw.wso2.com:9021',
      websub_event_receiver_https_endpoint  => 'https://gw.wso2.com:8021'
    }
  ]

  # TM endpoints
  $throttle_decision_endpoints = '"tcp://tm.wso2.com:5672"'
  $throttle_service_url        = 'https://tm.wso2.com:${mgt.transport.https.port}${carbon.context}services/'
  $throttling_url_group = [
    {
      traffic_manager_urls      => '"tcp://tm.wso2.com:9611"',
      traffic_manager_auth_urls => '"ssl://tm.wso2.com:9711"'
    }
  ]

  $event_listener_notification_endpoint = 'https://cp.wso2.com:${mgt.transport.https.port}/internal/data/v1/notify'

  $key_manager_server_url = 'https://km.wso2.com:${mgt.transport.https.port}${carbon.context}services/'
  $api_devportal_url      = 'https://cp.wso2.com:${mgt.transport.https.port}/devportal'
}
