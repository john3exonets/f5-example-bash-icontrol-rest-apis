#!/bin/bash
#
#  Sample F5 BIGIP AFM Configuration script
#  John D. Allen
#  April, 2016
#
#-----------------------------------------------------------------------------------
# Software is distributed on an "AS IS" basis,
# WITHOUT WARRANTY OF ANY KIND, either express or implied. See
# the License for the specific language governing rights and limitations
# under the License.
#
# The Initial Developer of the Original Code is F5 Networks,
# Inc. Seattle, WA, USA. Portions created by F5 are Copyright (C) 2016 F5 Networks,
# Inc. All Rights Reserved.
#
# Author: John D. Allen, Solution Architect, F5 Networks
# Email: john.allen@f5.com
#-----------------------------------------------------------------------------------
##  NOTES:
# This is an example Bash script to demonstrate how a BIGIP can be setup
# for basic firewall duty by using just the iControl REST API set.  It is using
# the 'Global' security context, which would affect *ALL* traffic moving through
# the BIGIP. Real world deployments would most likely use either a Route Domain
# or Virtual Server context for finer control of the security rule set.
#
# The script enables the AFM module, then waits for the BIGIP to reconfigure
# itself for firewall use.  When the script detects that the BIGIP is again ready
# for more instructions, it sets up the basic networking objects. Next it sets
# up a single Security Policy under which all the rules in the defined ruleset
# will be applied to.  Once the rules are all loaded, it then applies the
# policy to the Global Security context and exits. The rules have been
# simplified to make adding them easier. Normally you would add multiple ports
# to a single rule, but for this example we have seperated ports 80 and 443 into
# seperate rules.
#
# All of the steps and all of the JSON output are logged into the file
# defined below as a learning aid and to verify correct operation.
#
# If you have any questions, please feel free to contact me at:
# john.allen@f5.com
##
# V2:  Added SNMP Access and Disable Setup Wizard calls.
##

#-------------------------------------------------------
# Variables & Constants
#-------------------------------------------------------
## Constants
export BIGIP_Addrs="10.147.29.215"
export BIGIP_User="admin"
export BIGIP_Passwd="admin"
export HOSTNAME="fw1.nokia.com"

## Programs
#export CURL="/opt/vagrant/embedded/bin/curl"
export CURL="/usr/bin/curl"
export LOGFILE='./f5_fce.log'
if [ -e $LOGFILE ]; then
  echo "Removing old Log file."
  rm $LOGFILE
fi

## Network settings -- In a Cloud or SDN settings, these IP addresses should
##  be coming from either the SDN controller, Orchestration node, or VNFM.
INT_SELFIP="10.1.1.62/24"
EXT_SELFIP="10.2.2.58/24"
NEXT_HOP="10.2.2.1"
## v2: SNMP Access
SNMP_ALLOW_NETS="[\"127.\", \"10.\"]"

# Name of Policy under which all the rules in the ruleset are applied to
POLICYNAME="CPE_Security_Policy"

## Firewall Rules: Each var is one element of a rule. Rules are read top to bottom.
FWR_Name=("WebAccess" "SecureWebAccess" "SSH" "DNS" "FTP" "FTP-Data" "Telnet" "NTP" \
  "Ping" "SMTP" "BootPC" "TFTP" "POP3" "IMAP" "SNMP" "SNMP-Trap" "BGP" "LDAP" "SysLog")
FWR_Proto=("tcp" "tcp" "tcp" "udp" "tcp" "tcp" "tcp" "tcp" "icmp" "tcp" "tcp" "tcp" \
  "tcp" "tcp" "tcp" "tcp" "udp" "tcp" "udp")
FWR_Dest_Addrs=("any" "any" "any" "any" "any" "any" "any" "any" "any" "any" "any" "any" \
  "any" "any" "any" "any" "any" "any" "any")
FWR_Dest_Ports=("80" "443" "22" "53" "21" "20" "23" "123" "255" "25" "68" "69" "110" \
  "143" "161" "162" "179" "389" "514")

## Initial Curl connection timeout value in seconds.
TIMEOUT=5
## Maximum time for an API call to return. Depending on what you are doing,
##  this value should be quite large as some calls take a long time to
##  complete!  Testing your script should provide you with a good ideal
##  about what is too long.  I usually start at 120 seconds and go up from there.
MAXTIMEOUT=240

source ./F5CommonRESTAPIs.sh
log "** Adding Common iControl REST API Function **"

#-----------------------------------------------------------------------
#------------------[ Security specific Functions ]----------------------
#-----------------------------------------------------------------------

#-------------------------------------------------------
# Function: createSecurityPolicy()
#   Creates the base Security Policy on AFM.
# $1 => Policy Name
#-------------------------------------------------------
createSecurityPolicy() {
  OUT=$(restCall "POST" "/tm/security/firewall/policy" "{ \"name\": \"${1}\", \
    \"description\": \"Created by F5FirewallConfigExample script\" }")
  log "createSecurityPolicy(): `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["name"]') != $1 ]]; then
    echo "ERROR: Security Policy not successfully created."
    return 1
  fi
  return 0
}

#-------------------------------------------------------
# Function: addSecurityRule()
#  $1 => SecurityPolicyName to apply rule to
#  $2 => Name of Rule (Must match the "name" field in JSON payload)
#  $3 => Rule in JSON format
# Example Security Rule JSON:
#   { "name": "myRule1", "action": "accept", "place-before": "last",
#     "destination" : { "ports": [ { "name": "80" ] } }}, "ipProtocol": "any"
#   }
#-------------------------------------------------------
addRule() {
  OUT=$(restCall "POST" "/tm/security/firewall/policy/~Common~$1/rules" "$3")
  log "addRule(): `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["name"]') != $2 ]]; then
    echo "ERROR: Security Policy not successfully created."
    return 1
  fi
  #echo $OUT | python -mjson.tool
  return 0
}

#-------------------------------------------------------
# Function: applySecurityPolicy()
#   Attaches the passed Security Policy to the Global Security Context of AFM.
# $1 => SecurityPolicyName
#-------------------------------------------------------
applySecurityPolicy() {
  OUT=$(restCall "PATCH" "/tm/security/firewall/globalRules" "{ \"enforcedPolicy\": \"${1}\" }")
  log "applySecurityPolicy(): `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["kind"]') != "tm:security:firewall:global-rules:global-rulesstate" ]]; then
    echo "ERROR: Unable to attach Security Policy to Global context."
    return 1
  fi
  return 0
}

#-----------------------------------------------------------------------
#-----------------------------[  MAIN  ]--------------------------------
#-----------------------------------------------------------------------
log "*** Program Start ***"

# Check to make sure defined BIGIP is up and available for API calls
echo "Checking to see if we can talk to BIGIP..."
log "----Checking to see if we can talk to BIGIP..."
if (! whenAvailable); then
  echo "ERROR: BIGIP Not responding... Please check to see if it is running!"
  exit 1
fi

# Get the BIGIP Version
echo "Retrieving BIGIP Version number..."
log "---Retrieving BIGIP Version number..."
BIGIPVERSION=$(getVersion)
echo "    ${BIGIPVERSION}"

# V2:  Disable the Setup Wizard in case someone wants to look at the Admin GUI
echo "Disable the Setup Wizard on the Admin GUI."
log "----Disable the Setup Wizard on the Admin GUI."
OUT=$(restCall "PUT" "/tm/sys/global-settings" '{"guiSetup": "disabled"}')
log ":: `echo $OUT | python -mjson.tool`"
## Since its not critical if this call works or fails, I'm not even going to
## check the return.

###
###  This sample script assumes that the BIGIP has already been licensed,
###  and it has the AFM module set on in the License Key.
###

# Next we need to Enable the AFM modules and wait for the changes
# for AFM take effect.
echo "Turning on Advanced Firewall Module (AFM)."
log "----Turning on Advanced Firewall Module (AFM)."
enableModule "afm"
echo "Waiting for BIGIP to reconfigure itself for AFM. This can take a minute or two."
log "----Waiting for BIGIP to reconfigure itself for AFM. This can take a minute or two."
sleep 15
if (! waitForActiveStatus); then
  echo "ERROR: BIGIP Not in 'Active' status after enabling AFM module!!!"
  exit 1
fi
sleep 5
# Check to make sure BIGIP is back up and available for API calls
echo "Checking to see if we can talk to BIGIP again..."
log "----Checking to see if we can talk to BIGIP again..."
if (! whenAvailable); then
  echo "ERROR: BIGIP Not responding... Please check to see if it is running!"
  exit 1
fi

# Set the hostname to something Firewall-like
echo "Setting Hostname to ${HOSTNAME}."
log "----Setting Hostname to ${HOSTNAME}."
OUT=$(restCall "PATCH" "/tm/sys/global-settings" "{ \"hostname\": \"${HOSTNAME}\" }")
log "::`echo $OUT | python -mjson.tool`"
if [[ $(echo $OUT | jsonq '["hostname"]') != $HOSTNAME ]]; then
  echo "ERROR: BIGIP Hostname was not successfully set for some reason?"
  exit 1
fi

###
###  Network specific settings should go here. This demo script just uses
###   constants set at the start of the script, but in real life the data
###   would most likely come from an SDN controller, Orchestration system,
###   or VNFM node.
###

# Set up 'internal' VLAN & SelfIP
echo "Setting up 'internal' VLAN and SelfIP."
log "----Setting up 'internal' VLAN and SelfIP."
OUT=$(restCall "POST" "/tm/net/vlan" '{ "name": "internal", "interfaces": "1.1" }')
log "::`echo $OUT | python -mjson.tool`"
if [[ $(echo $OUT | jsonq '["name"]') != internal ]]; then
  echo "ERROR: BIGIP internal vlan interface was not set correctly or already existed."
  exit 1
fi

OUT=$(restCall "POST" "/tm/net/self" "{ \"name\": \"internal\", \"address\": \
   \"${INT_SELFIP}\", \"vlan\": \"internal\", \"allowService\": \"all\" }")
log "::`echo $OUT | python -mjson.tool`"
if [[ $(echo $OUT | jsonq '["address"]') != $INT_SELFIP ]]; then
  echo "ERROR: BIGIP internal SelfIP could not be set correctly or already existed."
  exit 1
fi

# Set up 'external' VLAN & SelfIP
echo "Setting up 'external' VLAN and SelfIP."
log "----Setting up 'external' VLAN and SelfIP."
OUT=$(restCall "POST" "/tm/net/vlan" '{ "name": "external", "interfaces": "1.2" }')
log "::`echo $OUT | python -mjson.tool`"
if [[ $(echo $OUT | jsonq '["name"]') != external ]]; then
  echo "ERROR: BIGIP external vlan interface was not set correctly or already existed."
  exit 1
fi

OUT=$(restCall "POST" "/tm/net/self" "{ \"name\": \"external\", \"address\": \
   \"${EXT_SELFIP}\", \"vlan\": \"external\", \"allowService\": \"all\" }")
log "::`echo $OUT | python -mjson.tool`"
if [[ $(echo $OUT | jsonq '["address"]') != $EXT_SELFIP ]]; then
  echo "ERROR: BIGIP external SelfIP could not be set correctly or already existed."
  exit 1
fi

###
###  Network routes out of the FW should be setup here.
###
echo "Set up next hop for Traffic flow."
log "----Set up next hop for Traffic flow."
OUT=$(setDefaultRoute "${NEXT_HOP}")
if ! $OUT; then
  echo "ERROR: Default Network Route could not be set. Does it already exist?"
  exit 1
fi

###
### v2: Set up SNMP Agent access subnets or hosts.
###
echo "Setup SNMP Agent access."
log "----Setup SNMP Agent access."
OUT=$(restCall "PUT" "/tm/sys/snmp" "{ \"allowed-addresses\": ${SNMP_ALLOW_NETS} }")
log ":: `echo $OUT | python -mjson.tool`"
if [[ $(echo $OUT | jsonq '["kind"]') != "tm:sys:snmp:snmpstate" ]]; then
  echo "ERROR: SNMP Agent access could not be set correctly"
  exit 1
fi

###
###  Setup Firewall Policy and Rules.
###   Rules are defined above in an array so that rulesets can be defined, swapped out
###   changed, etc. without having to modify the sample code.  More advanced rules will
###   require either a more detailed array, or a different method to add them.
###

# Setup initial Policy
echo "Setup initial Security Policy..."
log "----Setup initial Security Policy..."
OUT=$(createSecurityPolicy ${POLICYNAME})
if ! $OUT; then
  echo "ERROR: Security Policy creation failed for some reason. Does it already exist?"
  exit 1
fi

# Add Security Rules to the Policy
echo "Add Ruleset to Security Policy..."
log "----Add Ruleset to Security Policy..."
I=0
while [[ ${FWR_Name[$I]} != "" ]]; do
  JSON=""
  if [[ ${FWR_Proto[$I]} == "icmp" ]]; then
    JSON="{ \"name\": \"${FWR_Name[$I]}\", \"action\": \"accept\", \
    \"place-before\": \"last\", \"destination\": { }, \"icmp\": [ { \"name\": \"${FWR_Dest_Ports}\" } ], \
    \"ipProtocol\": \"${FWR_Proto[$I]}\" }"
  fi
  if [[ ${FWR_Proto[$I]} == "tcp" || ${FWR_Proto[$I]} == "udp" ]]; then
    JSON="{ \"name\": \"${FWR_Name[$I]}\", \"action\": \"accept\", \
    \"place-before\": \"last\", \"destination\": { \"addresses\": \"${FWR_Dest_Addrs[$I]}\", \
    \"ports\": [ { \"name\": \"${FWR_Dest_Ports[$I]}\" } ] }, \"ipProtocol\": \"${FWR_Proto[$I]}\" }"
  fi
  if [[ ${JSON} == "" ]]; then
    echo "Error - Invalid Security Rule in Array."
    exit 1
  fi
  OUT=$(addRule ${POLICYNAME} ${FWR_Name[$I]} "${JSON}")
  if ! $OUT; then
    echo "ERROR: Security Rule ${FWR_Name[$I]} was NOT added. Does it already exist?"
    exit 1
  fi
  I=$((I+1))
done

# Apply the Policy to the Global context. In real world settings, you would
# most likely apply the Policy to either a Route Domain or a Virtual Server.
echo "Apply Security Policy to the Global Security context."
log "----Apply Security Policy to the Global Security context."
OUT=$(applySecurityPolicy ${POLICYNAME})
if (! $OUT); then
  echo "ERROR - Security Policy could not be applied to the Global Security Context."
  exit 1
fi

###
### V5:  Setup wildcard listener to catch all traffic so it can be processed
###   by the Global security context.
###
echo "Create Listener Virtual Server to catch all inbound traffic."
log "----Create Listener Virtual Server to catch all inbound traffic."
OUT=$(addBasicVS "TrafficListener" "0.0.0.0" "any" "0" "any" "VS used to listen for all incoming traffic")
if ! $OUT; then
  echo "ERROR - TrafficListener VS was not created."
  exit 1
fi

echo "Modify VS for Automap"
log "----Modify VS for Automap"
OUT=$(modifyVS "TrafficListener" "{ \"sourceAddressTranslation\": { \"type\": \"automap\" } }")
if ! $OUT; then
  echo "Modifying VS did not work"
  exit 1
fi

# Save the configuration before exiting the script!!
echo "Saving the new Configuration..."
log "----Saving the new Configuration..."
OUT=$(saveConfig)
if (! $OUT); then
  exit 1
fi

echo "*** Firewall Configuration is now complete ***"
log "*** Firewall Configuration is now complete ***"
exit 0
