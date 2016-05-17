#!/bin/bash
#
#  Sample F5 BIGIP ADC Configuration script
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
##
# V2:  Added SNMP Access and Disable Setup Wizard calls.
##
##
# V4:  Results from Troubleshooting session 5/2/2016
##
##
# V5:  Adds options DNS Caching to DNS_Traffic_Passthrough VS.
##

#-------------------------------------------------------
# Variables & Constants
#-------------------------------------------------------
## Constants
export BIGIP_Addrs="10.147.29.215"
#export BIGIP_Addrs="10.147.185.205"
export BIGIP_User="admin"
export BIGIP_Passwd="admin"
export HOSTNAME="lb1.nokia.com"
export VSNAME="lb_urlfilter"
export VSNAME2="TrafficPassthrough"
export DNSVSNAME="DNS_Traffic_Passthrough_With_Cache"
export POOLNAME="urlfilter_pool"
##
## V5: Enable(0)/Disable(1) Optional DNS Caching
##
export DNSCACHE=0
export TRANSPARENTCACHENAME="DNS_Cache"
export DNSPROFILENAME="dns_cache"

## LB node list
LBLIST=("10.2.2.21" "10.2.2.22" "10.2.2.23")

## Network settings -- In a Cloud or SDN settings, these IP addresses should
##  be coming from either the SDN controller, Orchestration node, or VNFM.
INT_SELFIP="10.1.1.75/24"
EXT_SELFIP="10.2.2.65/24"
##
## NEXT_HOP is the Default Gateway setting.  ON the ADC, this should point to
## the 'internal' address of one of the URL Filter VNFs.
###
NEXT_HOP="10.2.2.1"
## v2: SNMP Access
SNMP_ALLOW_NETS="[\"127.\", \"10.\"]"

## Programs
#export CURL="/opt/vagrant/embedded/bin/curl"
export CURL="/usr/bin/curl"
export LOGFILE='./f5_adc.log'
if [ -e $LOGFILE ]; then
  echo "Removing old Log file."
  rm $LOGFILE
fi

# Initial Curl connection timeout value in seconds.
TIMEOUT=5
## Maximum time for an API call to return. Depending on what you are doing,
##  this value should be quite large as some calls take a long time to
##  complete!  Testing your script should provide you with a good ideal
##  about what is too long.  I usually start at 120 seconds and go up from there.
MAXTIMEOUT=120

source ./F5CommonRESTAPIs.sh
log "** Adding Common iControl REST API Function **"

#-----------------------------------------------------------------------
#--------------------[ Pool & Monitor Functions ]-----------------------
#-----------------------------------------------------------------------

#-------------------------------------------------------
# Function: addPool()
# $1 => Pool name
#-------------------------------------------------------
addPool() {
  OUT=$(restCall "POST" "/tm/ltm/pool" "{ \"name\": \"${1}\" }")
  log "addPool(): `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["kind"]') != "tm:ltm:pool:poolstate" ]]; then
    echo "Error: Unable to add Pool ${1}."
    return 1
  fi
  return 0
}

#-------------------------------------------------------
# Function: modifyPool()
# $1 => Pool name
# $2 => JSON payload
#-------------------------------------------------------
modifyPool() {
  OUT=$(restCall "PUT" "/tm/ltm/pool/${1}" "${2}")
  log "modifyPool(): `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["kind"]') != "tm:ltm:pool:poolstate" ]]; then
    echo "Error: Unable to modify Pool ${1}."
    return 1
  fi
  return 0
}

#-------------------------------------------------------
# Function: addPoolMember()
# $1 => Pool Name
# $2 => Member IP address
# $3 => Memeber Port address
#-------------------------------------------------------
addPoolMember() {
  OUT=$(restCall "POST" "/tm/ltm/pool/~Common~${1}/members" "{\"name\": \"/Common/${2}:${3}\", \"address\": \"${2}\"}")
  log "addPoolMember(): `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["kind"]') != "tm:ltm:pool:members:membersstate" ]]; then
    echo "Error: Unable to add memeber ${2} to Pool ${1}."
    return 1
  fi
  return 0
}

#-----------------------------------------------------------------------
#--------------------[ V5: DNS Caching Functions ]----------------------
#-----------------------------------------------------------------------

#-------------------------------------------------------
# Function:  createTransparentDNSCache()
# $1 => Name of Transparent Cache
#-------------------------------------------------------
createTransparentDNSCache() {
  OUT=$(restCall "POST" "/tm/ltm/dns/cache/transparent" "{\"name\": \"${1}\", \"answerDefaultZones\": \"no\" }")
  log "createTransparentDNSCache(): `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["kind"]') != "tm:ltm:dns:cache:transparent:transparentstate" ]]; then
    echo "Error: unable to create transparent DNS cache for some reason."
    return 1
  fi
  return 0
}

#-------------------------------------------------------
# Function: createDnsProfile()
# $1 => name of DNS profile
# $2 => name of DNS cache to use
#-------------------------------------------------------
createDnsProfile() {
  OUT=$(restCall "POST" "/tm/ltm/profile/dns" "{\"name\":\"${1}\", \"defaultsFrom\": \"dns\", \
    \"enableCache\":\"yes\", \"enableDnssec\":\"yes\", \"useLocalBind\":\"no\", \
    \"unhandledQueryAction\":\"allow\", \"cache\":\"/Common/${2}\" }")
  log "createDnsProfile(): `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["kind"]') != "tm:ltm:profile:dns:dnsstate" ]]; then
    echo "Error: unable to create transparent DNS cache for some reason."
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
### v3: Add VS to pass through DNS requests
###
echo "Setup DNS Pass-through Virtual Server."
log "----Setup DNS Pass-through Virtual Server."
OUT=$(addBasicVS "${DNSVSNAME}" "0.0.0.0" "any" "53" "udp" "DNS Pass-through")
if ! $OUT; then
  echo "Does VS already exist?"
  exit 1
fi

echo "Modify VS for Automap"
log "----Modify VS for Automap"
OUT=$(modifyVS "${DNSVSNAME}" "{ \"sourceAddressTranslation\": { \"type\": \"automap\" } }")
if ! $OUT; then
  echo "Modifying VS did not work"
  exit 1
fi

##
## v4: Changes from troubleshooting vCPE config 5/2/16 -- JDA
##
echo "Modify VS to Disable AutoTranslateAddress"
log "----Modify VS to Disable AutoTranslateAddress"
OUT=$(modifyVS "${DNSVSNAME}" "{ \"translateAddress\": \"disabled\" }")
if ! $OUT; then
  echo "Modifying VS did not work"
  exit 1
fi

###
### V5:  Add DNS Transparent Caching
###
echo "Create Transparent DNS Cache"
log "----Create Transparent DNS Cache"
OUT=$(createTransparentDNSCache "${TRANSPARENTCACHENAME}")
if ! $OUT; then
  echo "Unable to create Transparet DNS Cache for some reason"
  exit 1
fi

echo "Create DNS Profile for Tansparent Caching"
log "----Create DNS Profile for Tansparent Caching"
OUT=$(createDnsProfile "${DNSPROFILENAME}" "${TRANSPARENTCACHENAME}")
if ! $OUT; then
  echo "Unable to create DNS Profile for some reason"
  exit 1
fi

echo "Attach DNS Caching Profile to DNS Virtual Server"
log "----Attach DNS Caching Profile to DNS Virtual Server"
OUT=$(restCall "POST" "/tm/ltm/virtual/~Common~${DNSVSNAME}/profiles" \
  "{\"name\":\"${DNSPROFILENAME}\", \"fullPath\":\"/Common/${DNSPROFILENAME}\", \
  \"partition\":\"Common\" }")
log ":: `echo $OUT | python -mjson.tool`"
if [[ $(echo $OUT | jsonq '["kind"]') != "tm:ltm:virtual:profiles:profilesstate" ]]; then
  echo "Unable to attach DNS Profile to Virtual Server."
  exit 1
fi

###
### V5: Add Wildcard Traffic Passthrough
###
echo "Create a Virtual Server to intercept All Other traffic."
log "----Create a Virtual Server to intercept All Other traffic."
OUT=$(addBasicVS "${VSNAME2}" "0.0.0.0" "any" "0" "any" "Pass All Other Traffic Through")
if ! $OUT; then
  echo "Does it already exist?"
  exit 1
fi

echo "Modifying new VS to accept traffic only from the 'internal' VLAN"
log "----Modifying new VS to accept traffic only from the 'internal' VLAN"
OUT=$(modifyVS "${VSNAME2}" "{ \"vlansEnabled\": true, \"vlans\": [ \"/Common/internal\" ] }")
if ! $OUT; then
  echo "Does it already exist?"
  exit 1
fi

echo "Modify VS for Automap"
log "----Modify VS for Automap"
OUT=$(modifyVS "${VSNAME2}" "{ \"sourceAddressTranslation\": { \"type\": \"automap\" } }")
if ! $OUT; then
  echo "Modifying VS did not work"
  exit 1
fi

###
###  Setup LB
###  Process is fairly simple: setup the pool which will be attached to the
###  incoming VS, set the Health Checks used to monitor members of the pool, then
###  setup the VS and attach the pool to the VS.
###

echo "Setup LB Pool."
log "----Setup LB Pool."
OUT=$(addPool "${POOLNAME}")
if ! $OUT; then
  echo "ERROR: Pool ${POOLNAME} could not be set. Does it already exist?"
  exit 1
fi

# Pool has to be created first before some of the parameters can be changed.
OUT=$(modifyPool "${POOLNAME}" '{ "minUpMembersChecking": "enabled", "monitor": "/Common/gateway_icmp" }')
if ! $OUT; then
  echo "ERROR: Pool ${POOLNAME} could not be modifed successfully?"
  exit 1
fi

# Loop through array of nodes to add to LB pool
echo "Add nodes to LB Pool."
log "----Add nodes to LB Pool."
I=0
while [[ ${LBLIST[$I]} != "" ]]; do
  OUT=$(addPoolMember "${POOLNAME}" "${LBLIST[$I]}" "80")
  if ! $OUT; then
    echo "Error: Filter for ${LBLIST} was not added correctly!"
    exit 1
  else
    echo "    ${LBLIST[$I]}"
  fi
  I=$((I+1))
done

###
###  Network routes out of the Filter should be setup here, now that the
###  Pool has been created.
###
echo "Set up Default Route via Pool for Traffic flow."
log "----Set up Default Route via Pool for Traffic flow."
OUT=$(restCall "POST" "/tm/net/route" "{ \"name\": \"DefaultRoute\", \"partition\": \"Common\", \
    \"network\": \"default\", \"pool\": \"urlfilter_pool\" }")
if [[ $(echo $OUT | jsonq '["kind"]') != "tm:net:route:routestate" ]]; then
  echo "ERROR: Default Network Route could not be set. Does it already exist?"
  exit 1
fi

echo "Create a Virtual Server to intercept Port 80 traffic."
log "----Create a Virtual Server to intercept Port 80 traffic."
OUT=$(addBasicVS "${VSNAME}" "0.0.0.0" "any" "80" "tcp" "VS to LB to URL Filters")
if ! $OUT; then
  echo "Does it already exist?"
  exit 1
fi

echo "Modifying new VS for HTTP profile"
log "----Modifying new VS for HTTP profile"
OUT=$(addProfileToVS "${VSNAME}" "http")
if ! $OUT; then
  echo "Does it already exist?"
  exit 1
fi

echo "Adding LB Pool to new VS"
log "----Adding LB Pool to new VS"
OUT=$(modifyVS "${VSNAME}" "{ \"pool\": \"${POOLNAME}\"}")
if ! $OUT; then
  echo "Does it already exist?"
  exit 1
fi

echo "Modifying new VS to accept traffic only from the 'internal' VLAN"
log "----Modifying new VS to accept traffic only from the 'internal' VLAN"
OUT=$(modifyVS "${VSNAME}" "{ \"vlansEnabled\": true, \"vlans\": [ \"/Common/internal\" ] }")
if ! $OUT; then
  echo "Does it already exist?"
  exit 1
fi

echo "Modify VS for Automap"
log "----Modify VS for Automap"
OUT=$(modifyVS "${VSNAME}" "{ \"sourceAddressTranslation\": { \"type\": \"automap\" } }")
if ! $OUT; then
  echo "Modifying VS did not work"
  exit 1
fi

##
## v4: Changes from troubleshooting vCPE config 5/2/16 -- JDA
##
echo "Modify VS to Disable AutoTranslateAddress"
log "----Modify VS to Disable AutoTranslateAddress"
OUT=$(modifyVS "${VSNAME}" "{ \"translateAddress\": \"disabled\" }")
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

echo "*** ADC Configuration is now complete ***"
log "*** ADC Configuration is now complete ***"
exit 0
