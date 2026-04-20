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

# Class apim_km::params
# This class includes all the necessary parameters.
class apim_km::params inherits apim_common::params {

  $start_script_template = 'bin/key-manager.sh'
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
  $hostname = 'km.wso2.com'

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

  # CP event hub host
  $eventhub_service_host = 'cp.wso2.com'

  # Notification endpoint on CP
  $event_listener_notification_endpoint = 'https://cp.wso2.com:${mgt.transport.https.port}/internal/data/v1/notify'
}
