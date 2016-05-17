#!/bin/bash
#
#  Sample F5 BIGIP URL Filtering Configuration script
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
## V5:  Simplified traffic flow by using one wildcard VS.
##

#-------------------------------------------------------
# Variables & Constants
#-------------------------------------------------------
## Constants
export BIGIP_Addrs="10.147.29.215"
export BIGIP_User="admin"
export BIGIP_Passwd="admin"
export HOSTNAME="urlf1.nokia.com"
export GRPNAME="URL_Block_List"
export VSNAME="filt_in_HTTP"
export VSNAME2="TrafficPassthrough"

## iRule to install
IRULE_NAME="URL_Filter"
IRULE=$(cat <<EOF_IRULE
#
# URL Filtering iRule Sample
#
# F5 Networks
# (C) 2005, All Rights Reserved.
#
when RULE_INIT {
  log local0.info \"--init--\"
  set static::http_hdr \"<HTML><Head><TITLE>URL Filtering Service</TITLE></HEAD><BODY>\\\n\"
  set static::http_tail \"<p>Best Reguards,<br><br>Your Frendly ISP<br></BODY></HTML>\"
}
when HTTP_REQUEST {
  log local0.info \"Test for [HTTP::host]\"
  if { [class match [HTTP::host] contains ${GRPNAME}] } {
    log local0.info \"Match on [HTTP::host]\"
    set out \$static::http_hdr
    append out \"<h2>Blocked URL</h2>\\\nThis URL is on the 'Blocked Website List', and is not available.\\\n<br>\"
    append out \$static::http_tail
    HTTP::respond 200 content \$out
    return ok
  }
}

EOF_IRULE
)

## Filter list
FILT_LIST=("www.badwebsite.com" "www.facebook.com" "www.politicalsite.com" "www.sex.com" "www.naughtypictures.com")

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
export LOGFILE='./f5_ufe.log'
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
#---------------[ iRule & Data Group Functions]-------------------------
#-----------------------------------------------------------------------

#-------------------------------------------------------
# Function: createDataGroup()
# Creates and 'internal' Data Group on the BIGIP.
# $1 => name of Data Group
# $2 => DG type:  string, ip, integer
#-------------------------------------------------------
createDataGroup() {
  OUT=$(restCall "POST" "/tm/ltm/data-group/internal" "{ \"name\": \"${1}\", \"type\": \"${2}\" }")
  log "createDataGroup(): `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["kind"]') != "tm:ltm:data-group:internal:internalstate" ]]; then
    echo "ERROR: Unable to create Data Group ${1}"
    return 1
  fi
  return 0
}

#-------------------------------------------------------
# Function: addToDataGroup()
#   Adds to an existing Data Group.  This fucntion is much more complex,
#  since you need to capture all the existing entries into an JSON array,
#  insert the new entry, then send them all back. [Yes, it gets ugly with large lists]
# $1 => Name of Data Group
# $2 => Item to insert into group
#-------------------------------------------------------
addToDataGroup() {
  OUT=$(restCall "GET" "/tm/ltm/data-group/internal/~Common~${1}")
  log "addToDataGroup()[Initial GET]: `echo $OUT | python -mjson.tool`"
  ## Grab all the current records and add the new one to the end of the JSON array.
  if [[ $(echo $OUT | grep records) == "" ]]; then
    # No records yet, so add the first one.
    TT="[ { \"name\": \"${2}\" } ]"
  else
    TT=$(echo $OUT | python -c "import sys,json; input=json.load(sys.stdin); tt=input[\"records\"]; tt.append({ \"name\": \"${2}\" }); print json.dumps(tt)")
  fi
  log "addToDataGroup()[Record Insert]: `echo \"{ \"records\": ${TT} }\"`"
  ##  Overwrite the old records list with the new one.
  TS=$(echo "{ \"records\": ${TT} }")
  OUT=$(restCall "PUT" "/tm/ltm/data-group/internal/~Common~${1}" "{ \"records\": ${TT} }")
  log "addToDataGroup()[Write Back Results]: `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["kind"]') != "tm:ltm:data-group:internal:internalstate" ]]; then
    echo "ERROR: Data Group records were not added correctly."
    return 1
  fi
  return 0
}

#-------------------------------------------------------
# Function: addiRule()
# $1 => iRule name
# $2 => Text of iRule
#-------------------------------------------------------
addiRule() {
  OUT=$(restCall "POST" "/tm/ltm/rule" "{ \"name\": \"${1}\", \"partition\": \"Common\", \"apiAnonymous\": \"${2}\" }")
  log "addiRule(): `echo $OUT | python -mjson.tool`"
  if [[ $(echo $OUT | jsonq '["kind"]') != "tm:ltm:rule:rulestate" ]]; then
    echo "ERROR: iRUle ${1} not added correctly!"
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
###  Setup the URL Filter.
###  For this example, this is a simple iRule that checks the incoming HTTP traffic
###  host part of the ULR and looks to see if it matches anything on the
###  URL_Block_List Data Group.  If it finds a match, it will send back a basic
###  webpage that says the Website is on the Block list.
###
###  We will setup a 'wildcard' VS to intercept all HTTP Port 80 traffic, create the
###  Data Goupe that the iRule will use, create the iRule, then attach
###  the iRule to the new VS.  You would also want to set up a Port 443 VS in real life,
###  but for this example, we left it out.
###

echo "Create a Virtual Server to intercept Port 80 traffic."
log "----Create a Virtual Server to intercept Port 80 traffic."
OUT=$(addBasicVS "${VSNAME}" "0.0.0.0" "any" "80" "tcp" "Test virtual server by script")
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

##
## v4: Changes from troubleshooting vCPE config 5/2/16 -- JDA
##
echo "Modify VS to Disable AutoTranslateAddress"
log "----Modify VS to Disable AutoTranslateAddress"
OUT=$(modifyVS "${VSNAME2}" "{ \"translateAddress\": \"disabled\" }")
if ! $OUT; then
  echo "Modifying VS did not work"
  exit 1
fi

echo "Create Data Group and populate it"
log "----Create Data Group and populate it"
OUT=$(createDataGroup "${GRPNAME}" "string")
if ! $OUT; then
  echo "Does it already exist?"
  exit 1
fi

log "::"
I=0
while [[ ${FILT_LIST[$I]} != "" ]]; do
  OUT=$(addToDataGroup "${GRPNAME}" "${FILT_LIST[$I]}")
  if ! $OUT; then
    echo "Error: Filter for ${FILT_LIST} was not added correctly!"
    exit 1
  fi
  I=$((I+1))
  if [[ ${FILT_LIST[$I]} == "" ]]; then
    log "`echo $OUT | python -mjson.tool`"
  fi
done

echo "Create the iRule."
log "----Create the iRule."
OUT=$(addiRule "${IRULE_NAME}" "${IRULE}")
if ! $OUT; then
  echo "Does it already exist?"
  exit 1
fi

echo "Attach iRule to the HTTP VS."
log "----Attach iRule to the VS."
OUT=$(attachiRuleToVS "${IRULE_NAME}" "${VSNAME}")
if ! $OUT; then
  echo "Does it already exist?"
  exit 1
fi

# Save the configuration before exiting the script!!
echo "Saving the new Configuration..."
log "----Saving the new Configuration..."
OUT=$(saveConfig)
if (! $OUT); then
  exit 1
fi

echo "*** URL Filter Configuration is now complete ***"
log "*** URL Filter Configuration is now complete ***"
exit 0
