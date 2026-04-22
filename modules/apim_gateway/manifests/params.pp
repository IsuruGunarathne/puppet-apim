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

# Class apim_gateway::params
# This class includes all the necessary parameters.
class apim_gateway::params inherits apim_common::params {

  $start_script_template = 'bin/gateway.sh'
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
  $hostname = 'gw.wso2.com'

  # KM endpoint for token validation
  $key_manager_server_url = 'https://km.wso2.com:${mgt.transport.https.port}${carbon.context}services/'

  # TM endpoints for throttling
  $throttle_decision_endpoints = '"tcp://tm.wso2.com:5672"'
  $throttling_url_group = [
    {
      traffic_manager_urls      => '"tcp://tm.wso2.com:9611"',
      traffic_manager_auth_urls => '"ssl://tm.wso2.com:9711"'
    }
  ]

  $gateway_labels = ["Default"]

  $jms_conn_factory = 'amqp://${admin.username}:${admin.password}@clientid/carbon?brokerlist=\'tcp://${carbon.local.ip}:${jms.port}\''
}
