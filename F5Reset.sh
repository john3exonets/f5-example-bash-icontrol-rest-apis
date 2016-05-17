#!/bin/bash
#
#  Sample F5 BIGIP Reset Configuration script
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

#-------------------------------------------------------
# Variables & Constants
#-------------------------------------------------------
## Constants
export BIGIP_Addrs="10.147.29.214"
#export BIGIP_Addrs="10.147.185.205"
export BIGIP_User="admin"
export BIGIP_Passwd="admin"

##
## Modify these arrays to reflect the names of configuration objects you need
##   removed from the BIGIP configuration.
##
export GRPNAMES=("URL_Block_List")
export VSNAMES=("filt_in_HTTP" "HTTPS_Passthrough" "DNS_Traffic_Passthrough" "lb_urlfilter" \
  "TrafficListener" "TrafficPassthrough" "DNS_Traffic_Passthrough_With_Cache")
export POLICYNAMES=("CPE_Security_Policy")
export IRULE_NAMES=("URL_Filter" "Assign_BWC_Policy")
export POOLNAMES=("urlfilter_pool")
export DNSCACHENAMES=("DNS_Cache")
export PROFILENAMES=("dns/dns_cache")
export BWCNAMES=("Base_Traffic_BWC")


## Programs
#export CURL="/opt/vagrant/embedded/bin/curl"
export CURL="/usr/bin/curl"
export LOGFILE='./f5_reset.log'
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
MAXTIMEOUT=500

source ./F5CommonRESTAPIs.sh
log "** Adding Common iControl REST API Function **"

#-------------------------------------------------------
# Function: listActiveModules()
#-------------------------------------------------------
listActiveModules() {
  LIST=$(restCall "GET" "/tm/sys/provision/?\$select=name,level")
  CNT=$(echo $LIST | python -c "import sys,json; input=json.load(sys.stdin); print len(input['items'])")
  I=0
  local -a ARR=()
  while [[ $I != $CNT ]]; do
    LVL=$(echo $LIST | jsonq "[\"items\"][${I}][\"level\"]")
    if [[ $LVL != "none" ]]; then
      ARR[$I]=$(echo $LIST | jsonq "[\"items\"][${I}][\"name\"]")
    fi
    I=$((I+1))
  done
  echo ${ARR[@]}
}

#-----------------------------------------------------------------------
#-----------------------------[  MAIN  ]--------------------------------
#-----------------------------------------------------------------------
log "*** Program Start ***"

# Check to make sure defined BIGIP is up and available for API calls
echo "Checking to see if we can talk to BIGIP..."
log "---Checking to see if we can talk to BIGIP..."
if (! whenAvailable); then
  echo "ERROR: BIGIP Not responding... Please check to see if it is running!"
  exit 1
fi

# Get the BIGIP Version
echo "Retrieving BIGIP Version number..."
log "---Retrieving BIGIP Version number..."
BIGIPVERSION=$(getVersion)
echo "    ${BIGIPVERSION}"

# Remove Default Route
echo "Remove Default Route"
log "---Remove Default Route"
OUT=$(restCall "DELETE" "/tm/net/route/~Common~DefaultRoute")
if [[ $OUT != "" ]]; then
  log "Remove DefaultRoute: `echo $OUT | python -mjson.tool`"
fi

# Remove all named Virtual Servers
echo "Removing Virtual Servers..."
log "---Removing Virtual Servers..."
I=0
while [[ ${VSNAMES[$I]} != "" ]]; do
  OUT=$(restCall "DELETE" "/tm/ltm/virtual/${VSNAMES[$I]}" )
  if [[ $OUT == "" ]]; then
    echo "   ${VSNAMES[$I]}"
  else
    log "Remove VS: `echo $OUT | python -mjson.tool`"
  fi
  I=$((I+1))
done

# Disable any Global Security Policy
echo "Disable Global Secuirity Policy"
log "---Disable Global Secuirity Policy"
OUT=$(restCall "PATCH" "/tm/security/firewall/globalRules" "{ \"enforcedPolicy\": \"none\" }")
log "Disable Global security Policy: `echo $OUT | python -mjson.tool`"

# Remove any Security Policies
echo "Removing Security Policies..."
log "---Removing Security Policies..."
I=0
while [[ ${POLICYNAMES[$I]} != "" ]]; do
  OUT=$(restCall "DELETE" "/tm/security/firewall/policy/${POLICYNAMES[$I]}" )
  if [[ $OUT == "" ]]; then
    echo "   ${POLICYNAMES[$I]}"
  else
    log "Remove Security Policy: `echo $OUT | python -mjson.tool`"
  fi
  I=$((I+1))
done

# Remove any Pools
echo "Remove Pools..."
log "---Remove Pools..."
I=0
while [[ ${POOLNAMES[$I]} != "" ]]; do
  OUT=$(restCall "DELETE" "/tm/ltm/pool/${POOLNAMES[$I]}")
  #log "Remove Pool: `echo $OUT | python -mjson.tool`"
  if [[ $OUT == "" ]]; then
    echo "   ${POOLNAMES[$I]}"
  else
    log "Remove Pool: `echo $OUT | python -mjson.tool`"
  fi
  I=$((I+1))
done

# Remove all Nodes from list
echo "Remove all Nodes from List..."
log "---Remove all Nodes from List..."
LIST=$(restCall "GET" "/tm/ltm/node?\$select=name")
TEST=$(echo $LIST | python -c "import sys,json; input=json.load(sys.stdin); print('yes' if 'items' in input else 'no')")
if [[ $TEST == 'yes' ]]; then
  CNT=$(echo $LIST | python -c "import sys,json; input=json.load(sys.stdin); print len(input['items'])")
  I=0
  while [[ $I != $CNT ]]; do
    AA=$(echo $LIST | jsonq "[\"items\"][${I}][\"name\"]")
    # Remove the node
    OUT=$(restCall "DELETE" "/tm/ltm/node/~Common~${AA}")
    #log "Remove Node: `echo $OUT | python -mjson.tool`"
    echo "    ${AA}"
    I=$((I+1))
  done
fi

# Remove any iRules
echo "Remove iRules..."
log "---Remove iRules..."
I=0
while [[ ${IRULE_NAMES[$I]} != "" ]]; do
  OUT=$(restCall "DELETE" "/tm/ltm/rule/~Common~${IRULE_NAMES[$I]}")
  #log "Remove iRule: `echo $OUT | python -mjson.tool`"
  if [[ $OUT == "" ]]; then
    echo "    ${IRULE_NAMES[$I]}"
  else
    log "Remove iRule: `echo $OUT | python -mjson.tool`"
  fi
  I=$((I+1))
done

# Remove any Data Groups
echo "Remove Data Groups..."
log "---Remove Data Groups..."
I=0
while [[ ${GRPNAMES[$I]} != "" ]]; do
  OUT=$(restCall "DELETE" "/tm/ltm/data-group/internal/~Common~${GRPNAMES[$I]}")
  #log "Remove DataGroup: `echo $OUT | python -mjson.tool`"
  if [[ $OUT == "" ]]; then
    echo "    ${GRPNAMES[$I]}"
  else
    log "Remove DataGroup: `echo $OUT | python -mjson.tool`"
  fi
  I=$((I+1))
done

# Remove any Profiles
echo "Remove Profiles..."
log "---Remove Profiles..."
I=0
while [[ ${PROFILENAMES[$I]} != "" ]]; do
  OUT=$(restCall "DELETE" "/tm/ltm/profile/${PROFILENAMES[$I]}")
  #log "Remove Profile: `echo $OUT | python -mjson.tool`"
  if [[ $OUT == "" ]]; then
    echo "    ${PROFILENAMES[$I]}"
  else
    log "Remove Profile: `echo $OUT | python -mjson.tool`"
  fi
  I=$((I+1))
done

# Remove any DNS Caches
echo "Remove DNS Caches..."
log "---Remove DNS Caches..."
I=0
while [[ ${DNSCACHENAMES[$I]} != "" ]]; do
  OUT=$(restCall "DELETE" "/tm/ltm/dns/cache/transparent/~Common~${DNSCACHENAMES[$I]}")
  #log "Remove DNS Cache: `echo $OUT | python -mjson.tool`"
  if [[ $OUT == "" ]]; then
    echo "    ${DNSCACHENAMES[$I]}"
  else
    log "Remove DNS Cache: `echo $OUT | python -mjson.tool`"
  fi
  I=$((I+1))
done

# Remove any BWC Policies
echo "Remove BWC Policies..."
log "---Remove BWC Policies..."
I=0
while [[ ${BWCNAMES[$I]} != "" ]]; do
  if [[ $BIGIPVERSION == "12.0" ]]; then
    OUT=$(restCall "DELETE" "/tm/net/bwc/policy/~Common~${BWCNAMES[$I]}")
  fi
  if [[ $BIGIPVERSION == "11.6" ]]; then
    OUT=$(restCall "DELETE" "/tm/net/bwc-policy/~Common~${BWCNAMES[$I]}")
  fi
  if [[ $OUT == "" ]]; then
    echo "    ${BWCNAMES[$I]}"
  else
    log "Remove BWC Policies: `echo $OUT | python -mjson.tool`"
  fi
  I=$((I+1))
done

# Remove SelfIPs
echo "Remove SelfIPs..."
log "---Remove SelfIPs..."
LIST=$(restCall "GET" "/tm/net/self?\$select=name")
TEST=$(echo $LIST | python -c "import sys,json; input=json.load(sys.stdin); print('yes' if 'items' in input else 'no')")
if [[ $TEST == 'yes' ]]; then
  CNT=$(echo $LIST | python -c "import sys,json; input=json.load(sys.stdin); print len(input['items'])")
  I=0
  while [[ $I != $CNT ]]; do
    AA=$(echo $LIST | jsonq "[\"items\"][${I}][\"name\"]")
    # Remove the node
    OUT=$(restCall "DELETE" "/tm/net/self/~Common~${AA}")
    if [[ $OUT == "" ]]; then
      echo "    ${AA}"
    else
      log "Remove SelfIPs: `echo $OUT | python -mjson.tool`"
    fi
    I=$((I+1))
  done
fi

# Remove vlans
echo "Remove VLANs..."
log "---Remove VLANs..."
LIST=$(restCall "GET" "/tm/net/vlan?\$select=name")
TEST=$(echo $LIST | python -c "import sys,json; input=json.load(sys.stdin); print('yes' if 'items' in input else 'no')")
if [[ $TEST == 'yes' ]]; then
  CNT=$(echo $LIST | python -c "import sys,json; input=json.load(sys.stdin); print len(input['items'])")
  I=0
  while [[ $I != $CNT ]]; do
    AA=$(echo $LIST | jsonq "[\"items\"][${I}][\"name\"]")
    # Remove the node
    OUT=$(restCall "DELETE" "/tm/net/vlan/~Common~${AA}")
    if [[ $OUT == "" ]]; then
      echo "    ${AA}"
    else
      log "Remove SelfIPs: `echo $OUT | python -mjson.tool`"
    fi
    I=$((I+1))
  done
fi

# If AFM is enabled, disable and reboot
echo "Check to see if AFM is enabled..."
log "---Check to see if AFM is enabled..."
declare -a LIST=()
LIST=$(listActiveModules)
for MOD in ${LIST[@]}; do
  if [[ $MOD == "afm" ]]; then
    echo "AFM is Enabled, Disabling..."
    log "---AFM is Enabled, Disabling..."
    OUT=$(restCall "PUT" "/tm/sys/provision/afm" "{ \"level\": \"none\" }")
    sleep 10
    if (! waitForActiveStatus); then
      echo "ERROR: BIGIP Not in 'Active' status after disabling AFM module!!!"
      exit 1
    fi
    if (! whenAvailable); then
      echo "ERROR: BIGIP Not responding... Please check to see if it is running!"
      exit 1
    fi
    echo "Save Configuration..."
    log "---Save Configuration..."
    SAVE=$(saveConfig)
    echo "Rebooting BIGIP to complete AFM cleanup..."
    log "---Rebooting BIGIP to complete AFM cleanup..."
    rebootBIGIP
    sleep 60
    echo "Waiting for the BIGIP to come back up into an 'ACTIVE' state..."
    if (! whenAvailable ); then
      echo "BIGIP not responding within ${MAXTIMEOUT} seconds. Aborting..."
      exit 1
    fi
    if ( ! waitForActiveStatus ); then
      echo "BIGIP did not return to an 'ACTIVE' state after the reboot. Aborting..."
      exit 1
    fi
  fi
done

# Save Config
echo "Saving the new Configuration..."
log "----Saving the new Configuration..."
OUT=$(saveConfig)
if (! $OUT); then
  exit 1
fi

# Done!
echo "*** BIGIP Reset is now complete ***"
log "*** BIGIP Reset is now complete ***"
exit 0
