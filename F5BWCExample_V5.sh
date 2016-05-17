#!/bin/bash
#
#  Sample F5 BIGIP Bandwidth Controller Configuration script
#  John D. Allen
#  May, 2016
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

#-------------------------------------------------------
# Variables & Constants
#-------------------------------------------------------
## Constants
export BIGIP_Addrs="10.147.29.214"
export BIGIP_User="admin"
export BIGIP_Passwd="admin"
export HOSTNAME="bwc1.nokia.com"
export VSNAME="TrafficPassthrough"
export BWCNAME="Base_Traffic_BWC"
export BASEBWCRATE="2000000000"
export USERBWCRATE="200000000"

## iRule to install
IRULE_NAME="Assign_BWC_Policy"
IRULE=$(cat <<EOF_IRULE
#
# Assign_BWC_Policy: Attach a Dynamic BWC policy to each user.
#
# F5 Networks
# (C) 2014, All Rights Reserved.
#
when CLIENT_ACCEPTED {
  set client_session [IP::remote_addr]:[TCP::remote_port]
  BWC::policy attach ${BWCNAME} \$client_session
}

EOF_IRULE
)

###
### BWC Type:  This example script allows for both types of BWC configurations:
### 'static' and 'dynamic', and this constant configures which one is installed.
###
export BWCTYPE="dynamic"
#export BWCTYPE="static"

## Network settings -- In a Cloud or SDN settings, these IP addresses should
##  be coming from either the SDN controller, Orchestration node, or VNFM.
INT_SELFIP="10.1.1.71/24"
EXT_SELFIP="10.2.2.61/24"
NEXT_HOP="10.2.2.1"
## v2: SNMP Access
SNMP_ALLOW_NETS="[\"127.\", \"10.\"]"

## Programs
#export CURL="/opt/vagrant/embedded/bin/curl"
export CURL="/usr/bin/curl"
export LOGFILE='./f5_bwc.log'
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
#-------------------------[ BWC Functions]------------------------------
#-----------------------------------------------------------------------

#-------------------------------------------------------
# Function: addStaticBWCPolicy()
# $1 => name of BWC
# $2 => maxRate (in bps:  2 Gbps = 2,000,000,000 kbps)
#-------------------------------------------------------
addStaticBWCPolicy() {
  if [[ $BIGIPVERSION == "12.0" ]]; then
    OUT=$(restCall "POST" "/tm/net/bwc/policy" "{\"name\":\"${1}\", \"partition\":\"Common\", \
      \"dynamic\":\"disabled\", \"maxRate\":\"${2}\" }")
  fi
  if [[ $BIGIPVERSION == "11.6" ]]; then
    OUT=$(restCall "POST" "/tm/net/bwc-policy" "{\"name\":\"${1}\", \"partition\":\"Common\", \
      \"dynamic\":\"disabled\", \"maxRate\":\"${2}\" }")
  fi
  log "addBWCPolicy(): `echo $OUT | python -mjson.tool`"
  if [[ $BIGIPVERSION == "12.0" ]]; then
    if [[ $(echo $OUT | jsonq '["kind"]') != "tm:net:bwc:policy:policystate" ]]; then
      echo "ERROR: Unable to create BWC Policy ${1}"
      return 1
    fi
    return 0
  fi
  if [[ $BIGIPVERSION == "11.6" ]]; then
    if [[ $(echo $OUT | jsonq '["kind"]') != "tm:net:bwc-policy:bwc-policystate" ]]; then
      echo "ERROR: Unable to create BWC Policy ${1}"
      return 1
    fi
    return 0
  fi
}

#-------------------------------------------------------
# Function: addDynamicBWCPolicy()
# $1 => name of BWC
# $2 => maxRate (in bps:  2 Gbps = 2,000,000,000 bps)
# $3 => maxUserRate (in bps)
#-------------------------------------------------------
addDynamicBWCPolicy() {
  if [[ $BIGIPVERSION == "12.0" ]]; then
    OUT=$(restCall "POST" "/tm/net/bwc/policy" "{\"name\":\"${1}\", \"partition\":\"Common\", \
      \"dynamic\":\"enabled\", \"maxRate\":\"${2}\", \"maxUserRate\":\"${3}\" }")
  fi
  if [[ $BIGIPVERSION == "11.6" ]]; then
    OUT=$(restCall "POST" "/tm/net/bwc-policy" "{\"name\":\"${1}\", \"partition\":\"Common\", \
      \"dynamic\":\"enabled\", \"maxRate\":\"${2}\", \"maxUserRate\":\"${3}\" }")
  fi
  log "addBWCPolicy(): `echo $OUT | python -mjson.tool`"
  if [[ $BIGIPVERSION == "12.0" ]]; then
    if [[ $(echo $OUT | jsonq '["kind"]') != "tm:net:bwc:policy:policystate" ]]; then
      echo "ERROR: Unable to create BWC Policy ${1}"
      return 1
    fi
    return 0
  fi
  if [[ $BIGIPVERSION == "11.6" ]]; then
    if [[ $(echo $OUT | jsonq '["kind"]') != "tm:net:bwc-policy:bwc-policystate" ]]; then
      echo "ERROR: Unable to create BWC Policy ${1}"
      return 1
    fi
    return 0
  fi
}

#-------------------------------------------------------
# Function: attachStaticBWCtoVS()
# $1 => BWC Name
# $2 => VS Name
#-------------------------------------------------------
attachStaticBWCtoVS() {
  OUT=$(restCall "PATCH" "/tm/ltm/virtual/${2}" "{ \"bwcPolicy\":\"/Common/${1}\" }")
  log "attachStaticBWCtoVS(): `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["kind"]') != "tm:ltm:virtual:virtualstate" ]]; then
    echo "ERROR: BWC Policy ${1} was not added to VS ${2}"
    return 1
  fi
  return 0
}

#-------------------------------------------------------
# Function: modifyVLANforSrcHash()
# $1 => Name of VLAN
#-------------------------------------------------------
modifyVLANforSrcHash() {
  OUT=$(restCall "PATCH" "/tm/net/vlan/~Common~${1}" "{\"cmpHash\":\"src-ip\"}")
  log "modifyVLANforSrcHash(): `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["kind"]') != "tm:net:vlan:vlanstate" ]]; then
    echo "ERROR - VLAN ${1} was not modified for Source IP Hashing."
    return 1
  fi
  return 0
}

#-----------------------------------------------------------------------
#------------------------[ iRule Functions]-----------------------------
#-----------------------------------------------------------------------

#-------------------------------------------------------
# Function: addiRule()
# $1 => iRule name
# $2 => Text of iRule
#-------------------------------------------------------
addiRule() {
  OUT=$(restCall "POST" "/tm/ltm/rule" "{ \"name\": \"${1}\", \"partition\": \"Common\", \"apiAnonymous\": \"${2}\" }")
  log "addiRule(): `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["kind"]') != "tm:ltm:rule:rulestate" ]]; then
    echo "ERROR: iRule ${1} not added correctly!"
    return 1
  fi
  return 0
}

#-------------------------------------------------------
# Function: attachiRuleToVS()
# $1 => iRule Name
# $2 => VS Name
#-------------------------------------------------------
attachiRuleToVS() {
  OUT=$(restCall "PATCH" "/tm/ltm/virtual/${2}" "{ \"rules\": [\"/Common/${1}\"] }")
  log "attachiRuleToVS(): `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["kind"]') != "tm:ltm:virtual:virtualstate" ]]; then
    echo "ERROR: iRule ${1} was not added to VS ${2}"
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
###  Network routes out of the Filter should be setup here.
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
### Create and Attach Bandwidth Controller (BWC)
###
### There are two options for BWC: 'Static' BWC is a very simple bandwidth
### limiter that is set for a specific bandwidth to allow through on the VS
### to which the BWC Policy is attached to. 'Dynamic' BWC requires a bit more
### work to set up, in that you must assign the BWC policy to each 'user', and
### this is accomplished by creating and iRule to do the assignment, and then
### the iRule is attached to a traffic VS. It also requires that the VLAN that
### the traffic is coming into have its 'CMP Hash' set to 'Source Address' so
### that users can be more easily identified and their traffic passed through
### the correct TMM core that is handling their traffic.
###

if [[ $BWCTYPE == "static" ]]; then
  echo "Creating Static BWC Policy."
  log "----Creating Static BWC Policy."
  OUT=$(addStaticBWCPolicy "${BWCNAME}" "${BASEBWCRATE}")
  if ! $OUT; then
    echo "Does it already exist?"
    exit 1
  fi
fi
if [[ $BWCTYPE == "dynamic" ]]; then
  echo "Creating Dynamic BWC Policy."
  log "----Creating Dynamic BWC Policy."
  OUT=$(addDynamicBWCPolicy "${BWCNAME}" "${BASEBWCRATE}" "${USERBWCRATE}")
  if ! $OUT; then
    echo "Does it already exist?"
    exit 1
  fi

  echo "Modifying 'internal' VLAN for Dynamic BWC Operations."
  log "----Modifying 'internal' VLAN for Dynamic BWC Operations."
  OUT=$(modifyVLANforSrcHash "internal")
  if ! $OUT; then
    echo "Does it already exist?"
    exit 1
  fi
fi

###
### Add Wildcard Traffic Passthrough
###
echo "Create a Virtual Server to intercept All traffic."
log "----Create a Virtual Server to intercept All Other traffic."
OUT=$(addBasicVS "${VSNAME}" "0.0.0.0" "any" "0" "any" "Pass All Other Traffic Through")
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

echo "Modify VS to Disable AutoTranslateAddress"
log "----Modify VS to Disable AutoTranslateAddress"
OUT=$(modifyVS "${VSNAME}" "{ \"translateAddress\": \"disabled\" }")
if ! $OUT; then
  echo "Modifying VS did not work"
  exit 1
fi

if [[ $BWCTYPE == "static" ]]; then
  echo "Adding Static BWC Policy to new VS."
  log "----Adding Static BWC Policy to new VS."
  OUT=$(attachStaticBWCtoVS "${BWCNAME}" "${VSNAME}")
  if ! $OUT; then
    echo "Modifying VS did not work"
    exit 1
  fi
fi
if [[ $BWCTYPE == "dynamic" ]]; then
  echo "Create BWC Assignment iRule."
  log "----Create BWC Assignment iRule."
  OUT=$(addiRule "${IRULE_NAME}" "${IRULE}")
  if ! $OUT; then
    echo "Does it already exist?"
    exit 1
  fi

  echo "Adding iRule to new VS."
  log "----Adding iRule to new VS."
  OUT=$(attachiRuleToVS "${IRULE_NAME}" "${VSNAME}")
  if ! $OUT; then
    echo "Does it already exist?"
    exit 1
  fi
fi

# Save the configuration before exiting the script!!
echo "Saving the new Configuration..."
log "----Saving the new Configuration..."
OUT=$(saveConfig)
if (! $OUT); then
  exit 1
fi

echo "*** BWC Configuration is now complete ***"
log "*** BWC Configuration is now complete ***"
exit 0
