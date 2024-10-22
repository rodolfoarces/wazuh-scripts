#!/usr/bin/env /var/ossec/framework/python/bin/python3.10
import sys
import json
import requests
from requests.auth import HTTPBasicAuth

# Read configuration parameters
# <hook_url>http://redmine.example.com:3000</hook_url>
# <api_key>aa112233xxxyyzz778899:1</api_key>
# Alert information
alert_file = open(sys.argv[1])
# Connection
api_key = sys.argv[2].split(':')[0]
project_id = sys.argv[2].split(':')[1]
# URL
hook_url = sys.argv[3] + '/issues.json'

# Read the alert file
alert_json = json.loads(alert_file.read())
alert_file.close()

#print (sys.argv)
#print (json.dumps(alert_json))

# Extract issue fields
alert_level = alert_json['rule']['level']
rule_id = alert_json['rule']['id']
subject = alert_json['rule']['description']
agent_id = alert_json['agent']['id']
agent_name = alert_json['agent']['name']

description = '- Rule ID:' + rule_id + '\n- Agent ID:' + agent_id + '\n- Agent Name:' + agent_name + '\n- Description' + subject + '\n- Alert Level:' + str(alert_level)

# Generate request
## Include the API key header
headers = {'Content-type': 'application/json', 'X-Redmine-API-Key': api_key }
## Request content
issue_data = {
    "issue": {
        "project_id": project_id,
        "subject": subject,
        "priority_id": 1,
        "tracker_id": 3,
        "description": description
        #"custom_fields":[{ "alert_level": alert_level }]
    }
    }
# Send the request
try:
    response = requests.post(hook_url, json=issue_data, headers=headers, verify=False)
    #print (response.content.decode('utf-8'))
except:
    print ("Error")
    sys.exit(1)
sys.exit(0)
