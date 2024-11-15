#!/bin/bash
# NAME: node-check.sh
#
# DESCRIPTION:
# This script will process an array of nodes to determine if the node is
# up and running.
#

AUTHOR="Jeffrey Gordon"
RELDATE="11/14/2024"
VERSION="0.20"
##############################################################################

### [ Routines ] #############################################################
required_utils=("expect" "nc" "curl" "strings")

# Confirm required utilities are installed.
for util in "${required_utils[@]}"; do
  [ -z "$(command -v "$util")" ] && echo "ERROR: the utility '$util' is required to be installed." >&2 && exit 1
done

# ---[ Usage Statement ]------------------------------------------------------
__usage() {
  echo "
  ${0##*/} | Version: ${VERSION} | ${RELDATE} | ${AUTHOR}

  Check nodes Ready status in k8s.
  ----------------------------------------------------------------------------

  This script will check all nodes in the cluster to determine if any of
  the nodes are not "Ready". If detected, the script will run a defined failure script.

  --debug           : Show expect screen scrape in progress.
  -c, --config      : Full path and name of configuration file.
  -a, --all         : Process all nodes.
  -r, --recover     : Run the recovery script for a single node
  -l, --list        : List defined nodes within the script.
  -h, --help        : This usage statement.
  -v, --version     : Return script version.

  ${0##*/} [--debug] [-c <path/name.config>] [-flags] [-a | <nodename>]

  Default configuration file: ${configfile}
  "
}

# ---[ Error Handler ]--------------------------------------------------------
# Write error messages to STDERR.

__error_message() {
  echo "[$(date "$timestamp_format")]: $*" >&2
}

# ---[ How to handle notifications ]------------------------------------------
# This is a user defined area of how to handle notifications in the script.
# This can be changed to send email notification or slack channel webhook, etc.

__send_notification() {
  local message="$1"
  # Send notification via webhook
  if [[ -n "$message" ]]; then
    if curl -X POST -H 'Content-type: application/json' --data '{"text":"'"$message"'"}' "$webhook" > /dev/null 2> /dev/null
    then
      echo "-- -- Notification sent (${message})"
    fi
  fi

  if [[ -n "$pushover_token" ]]; then
    __send_pushover "$message"
  fi
}

__send_pushover() {
  local message="$1"
  if [[ -n "$message" ]]; then
    if curl -s --form-string "token=$pushover_token" --form-string "user=$pushover_userkey" --form-string "message=$message" https://api.pushover.net/1/messages.json 2> /dev/null
    then
      echo "-- -- Pushover sent (${message})"
    fi
  fi
}

# ---[ What to do when node recovers ]------------------------
# This is user defined area of what to do node is recovered.
# You can copy & paste this into your configuration file instead of
# making modifications to this script.

__node_recover_payload() {
  local node="$1"
  local result=1

  #This example applies taints to the Kubernetes node.
  echo "-- Attempting untaint of node: $node"
  kubectl taint nodes "$node" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute- 2>&1
  result=$?

  if [ $result -eq 0 ]; then
    kubectl taint nodes "$node" node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule- 2>&1
    result=$?
  fi

  if [ $result -eq 0 ]; then
    message="Node taints removed from $node sucessful."
  else
    message="FAILED to remove node taints on $node."
  fi
}

# ---[ What to do when node unavilable or failed ]------------------------
# This is user defined area of what to do if node is not available or
# failed.  You can copy & paste this into your configuration file instead of
# making modifications to this script.

__node_failed_payload() {
  local node="$1"
  local result=1

  #This example applies taints to the Kubernetes node.
  echo "-- Attempting fence of node: $node"
  kubectl taint nodes "$node" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute --overwrite=true 2>&1
  result=$?

  if [ $result -eq 0 ]; then
    kubectl taint nodes "$node" node.kubernetes.io/out-of-service=nodeshutdown:NoSchedule --overwrite=true 2>&1
    result=$?
  fi

  if [ $result -eq 0 ]; then
    message="Node taints to fence $node sucessful."
  else
    message="FAILED to apply node taints on $node."
  fi
  
  IFS=$'\n'
  for podline in $(kubectl --context $context get pods --all-namespaces -o wide --field-selector spec.nodeName=$node); do
    IFS=' '
    set $podline
    namespace=$1
    pod=$2
    status=$4
    if [[ $status = "Terminating" ]]; then
      echo "kubectl --context $context delete pod $pod --grace-period=0 --force --namespace $namespace"
    fi
  done

 echo "-- -- $message"
__send_notification "$message"

  return $result
}


# ---[ Create node State File ]-----------------------------------------------
# This will create a simple file with the name of the node used to indicate
# that node is down. The datestamp in seconds (since the UNIX epoch) is written
# to the file to track when it was marked as down. If the file already exists
# do not create a new one, need to preserve the timestamp.

__create_node_state() {
  local node="$1"
  local result=1
  echo "Create Node State File"
  if [[ -n "$node" ]]; then
    if [[ ! -f "${configdir}/${node}.down" ]]; then
      if date +%s > "${configdir}/${node}.down"
      then
        result=0
      else
        __error_message "error: unable to create node state file - ${configdir}/${node}.down"
      fi
    fi
  else
    __error_message "error: node required"
    exit 2
  fi

  return $result
}

# ---[ Check Node State File ]------------------------------------------------
# Check if a Node State File exists for the specified node.  If it does exist
# and is older than "node_state_retry_min" (minutes) then update timestamp to
# now. This will allow a notification to be triggered again.

__check_node_state() {
  local node="$1"
  local result=1

  if [[ -n "$node" ]]; then
    if [[ -f "${configdir}/${node}.down" ]]; then
      # if Host State File is older than retry minutes, uptime timestamp (allows next notifications again)
      # return code to allow notification
      if [[ -n $(find "${configdir}" -name "${node}.down" -mmin "+${node_state_retry_min}" -type f) ]]; then
        find "${configdir}" -name "${node}.down" -mmin "+${node_state_retry_min}" -type f -exec touch {} \;
        result=0
      fi
    else
      # no existing host state file, return code to allow notification
      result=0
    fi
  else
    __error_message "error: node required"
    exit 2
  fi
  return $result
}

# --- [ Get Node Down Duration ]-----------------------------------------------
# Get the Node down timestamp from the node down file and calculate down
# duration to now in seconds. Returns number of seconds node has been down.

__get_node_down_duration_seconds() {
  local node="$1"
  local result=1
  local initial_down=""
  local now=""

  if [[ -n "$node" ]]; then
    if [[ -f "${configdir}/${node}.down" ]]; then
      initial_down=$(cat "${configdir}/${node}.down")
      now=$(date +%s)
      echo $((now - initial_down))
    else
      __error_message "error: node not down"
      exit 2
    fi
  else
    __error_message "error: node required"
    exit 2
  fi
  return $result
}

# ---[ Remove Node State File ]------------------------------------------------
# Delete specified Node State File if it exists

__remove_node_state() {
  local node="$1"
  local result=1

  if [[ -n "$node" ]]; then
    if [[ -f "${configdir}/${node}.down" ]]; then
      rm "${configdir}/${node}.down" && result=0
    fi
  else
    __error_message "error: node required"
    exit 2
  fi
  return $result
}

# ---[ Primary Monitoring Loop ]----------------------------------------------
# This will loop over each defined hostname to determine if SSH port is open
# which indicates host is healthy.  If SSH ports are not open, the script will
# detect if Dropbear ports are opened, if detected it will attempt to answer
# passphrase prompt with the supplied passphrase

__process_all_nodes() {
  local passphrase="$1"
  local result=1
  local node_down_seconds=""
  local now=""
  local context="main" ##add this to options and config

  IFS=$'\n'
  for nodeline in $(kubectl --context $context get nodes --no-headers); do
    IFS=' '
    set $nodeline
    node=$1
    readyState=$2

    if [[ $readyState != "Ready" ]]; then
      if __check_node_state "$node"
      then
        __send_notification "ERROR: $node failed. Node down?"
        __create_node_state "$node"
      fi
      # See if host down is longer than host failed threshold
      node_down_seconds=$(__get_node_down_duration_seconds "$node")
      if [[ "$node_down_seconds" -gt $((node_state_failed_threshold * 60)) ]];then
        # Process user defined steps to handle failed dropbear
        echo "-- Node $node failed threshold reached"
        __node_failed_payload "$node"
      else
        # Calculate when node failed threshold will be reached
        now=$(date +%s)
        echo "-- Node $node failed threshold set at: $(date $date_compare_option$(( now + (node_state_failed_threshold * 60) - node_down_seconds)) "$timestamp_format")"
      fi
    else
      if __remove_node_state "$node"
      then
        __node_recover_payload "$node"
        __send_notification "$node is now back on-line."
      fi
    fi
  done
}

# --- [ List Node ]------------------------------------------------
# List all nodes.

__list_nodes() {
  local node=""
  local state=""
  local now=""
  now=$(date +%s)
  echo "Node(s) defined:"
  IFS=$'\n'
  for nodeline in $(kubectl  --context $context get nodes --no-headers); do
    IFS=' '
    set $nodeline
    node=$1
    readyState=$2
    if [[ -f "${configdir}/${node}.down" ]]; then
      node_down_seconds=$(__get_node_down_duration_seconds "$node")
      state="[ Node marked down via state file ${configdir}/${node}.down since $(date $date_compare_option$(( now - node_down_seconds)) "$timestamp_format") ]"
    else
      state=""
    fi
    echo "${node} ${state}"
  done
}

# --- [ Load Configuration File ]---------------------------------------------
__load_config_file() {
  local configfile="$1"

  echo "-- ${0##*/} v${VERSION}: Loading configuration file: $configfile"
  if [ -f "$configfile" ]; then
    # shellcheck source=/dev/null
    source "$configfile"
  else
    __error_message "error: configuration file not found."
    #exit 2
  fi
}

# --- [ Define Constants / Default Values ]------------------------------------
FALSE=0
TRUE=1
DEBUG="$FALSE"
timestamp_format="+%Y-%m-%dT%H:%M:%S%z"  # 2023-09-25T12:56:02-0400

if date --version >/dev/null 2>&1 ; then
    echo Using GNU date
    date_compare_option="-d @"
else
    echo Not using GNU date
    date_compare_option="-j -r "
fi

# Default values, use the config file to override these!
configdir="$HOME/.config/node-check"
configfile="${configdir}/node-check.conf"
context="main"
hostnames=("localhost")
node_state_retry_min="59" # minutes
node_state_failed_threshold="10" # minutes
webhook="not_defined"

# Make sure directory to hold state information exists
if ! mkdir -p "${configdir}"
then
  __error_message "error: unable to create state directory: ${configdir}"
  exit 2
fi

# --- [ Process Argument List ]-----------------------------------------------
if [ "$#" -ne 0 ]; then
  while [ "$#" -gt 0 ]
  do
    case "$1" in
    -a|--all)
      __load_config_file "$configfile"
      __process_all_nodes
      ;;
    -c|--config)
      configfile=$2
      ;;
    --debug)
      DEBUG="$TRUE"
      ;;
    -h|--help)
      __usage
      exit 0
      ;;
    -l|--list)
      __load_config_file "$configfile"
      __list_nodes
      ;;
    -r|--recover)
      __load_config_file "$configfile"
      __node_recover_payload "$2"
      ;;
    -v|--version)
      echo "$VERSION"
      exit 0
      ;;
    --)
      break
      ;;
    -*)
      __error_message "Invalid option '$1'. Use --help to see the valid options"
      exit 2
      ;;
    # an option argument, continue
    *)  ;;
    esac
    shift
  done
else
  __usage
  exit 1
fi
