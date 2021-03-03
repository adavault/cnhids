#!/bin/bash
#shellcheck disable=SC2009,SC2034,SC2059,SC2206,SC2086,SC2015,SC2154
#shellcheck source=/dev/null

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

NO_INTERNET_MODE="N"                       # To skip checking for auto updates or make outgoing connections to guild-operators github repository

#CNODE_NAME='cnode'                        # Alternate name for top level folder, non alpha-numeric chars will be replaced with underscore (Default: cnode)
CNODE_IP=127.0.0.1                         # Default IP/FQDN or pass multiple as comma delimited string with no whitespace e.g. host1.domain,host2.domain
CNODE_PORT=12798                           # Default monitoring port used by node for metrics (can be edited in config.json on node)
GRAFANA_HOST=0.0.0.0                       # Default IP address for Grafana (bind to server public interface)
GRAFANA_PORT=5000                          # Default port used by Grafana
PROM_HOST=127.0.0.1                        # Default Prometheus host (bind to localhost as only accessed by Grafana)
PROM_PORT=9090                             # Default Prometheus port (only accessed by Grafana)
NEXP_PORT=9091                             # Default Node Exporter port

PROJ_PATH=/opt/cardano/monitoring          # Default install path

TIMEZONE="Europe/London"                   # Default Timezone for promtail config file, change as needed for your server timezone

######################################
# Static Variables                   #
######################################

ARCHS=("darwin-amd64" "linux-amd64"  "linux-armv6")
TMP_DIR=$(mktemp -d "/tmp/cnode_monitoring.XXXXXXXX")
PROM_VER=2.24.1
GRAF_VER=7.4.0
NEXP_VER=1.0.1
OSSEC_VER=3.6.0
PROMTAIL_VER=2.1.0
LOKI_VER=2.1.0
OSSEC_METRICS_VER=0.1.0
NEXP="node_exporter"

# guildops URLs
REPO="https://github.com/cardano-community/guild-operators"
REPO_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators"
URL_RAW="${REPO_RAW}/${BRANCH}"

# tokenised config file URLs
PROM_CONF_URL="https://raw.githubusercontent.com/cyber-russ/cnhids/main/prometheus.yml"
GRAF_CONF_URL="https://raw.githubusercontent.com/cyber-russ/cnhids/main/grafana-datasources.yaml"
PROMTAIL_CONF_URL="https://raw.githubusercontent.com/cyber-russ/cnhids/main/promtail.yaml"
LOKI_CONF_URL="https://raw.githubusercontent.com/cyber-russ/cnhids/main/loki-config.yaml"
OSSEC_CONF_URL="https://raw.githubusercontent.com/cyber-russ/cnhids/main/ossec.conf"
OSSEC_METRICS_CONF_URL=""

# performance dashboard URLs
SKY_DB_URL="https://raw.githubusercontent.com/Oqulent/SkyLight-Pool/master/Haskel_Node_SKY_Relay1_Dash.json"
IOHK_DB="cardano-application-dashboard-v2.json"
IOHK_DB_URL="https://raw.githubusercontent.com/input-output-hk/cardano-ops/master/modules/grafana/cardano/$IOHK_DB"
ADV_DB_URL="https://raw.githubusercontent.com/cyber-russ/adavault-dashboard/main/adv-dashboard-grafana.json"

# cnHids dashboard URL
CNHIDS_DB_URL="https://raw.githubusercontent.com/cyber-russ/cnhids/main/grafana-dashboard.json"

#Why is this export statement here?...presumably so spawned processes have access to vars...
export CNODE_IP CNODE_PORT PROJ_PATH TMP_DIR

# Install defaults (equivalent to a local installation on a single node)- these are overridden by args
INSTALL_MON=true
INSTALL_CNHIDS=true
INSTALL_NODE_EXP=true
INSTALL_OSSEC_AGENT=false

######################################
# Do NOT modify code below           #
######################################
DEBUG="N"
SETUP_MON_VERSION=2.0.0

IP_ADDRESS=$(hostname -I)
echo "IP ADDRESS:$IP_ADDRESS"

dirs -c # clear dir stack
CNODE_PATH="/opt/cardano"
CNODE_HOME=${CNODE_PATH}/${CNODE_NAME}
CNODE_VNAME=$(echo "$CNODE_NAME" | awk '{print toupper($0)}')
[[ -z "${BRANCH}" ]] && BRANCH="master"

######################################
# Functions                          #
######################################

#clean_up () {
#    echo "Cleaning up..." >&2
#    $DBG rm -rf "$TMP_DIR"
#    RES=$1
#    exit "${RES:=127}"
#}

get_input() {
  printf "%s (default: %s): " "$1" "$2" >&2; read -r answer
  if [ -z "$answer" ]; then echo "$2"; else echo "$answer"; fi
}

get_answer() {
  printf "%s (yes/no): " "$*" >&2; read -r answer
  while : 
  do
    case $answer in
    [Yy]*)
      return 0;;
    [Nn]*)
      return 1;;
    *) printf "%s" "Please enter 'yes' or 'no' to continue: " >&2; read -r answer
    esac
  done
}

versionCheck() { printf '%s\n%s' "${1//v/}" "${2//v/}" | sort -C -V; } #$1=available_version, $2=installed_version


message () {
    echo -e "$*" >&2
    exit 127
}

get_idx () {
    case $OSTYPE in
        "darwin"*)
            IDX=0
        ;;
        "linux-gnu"*)
            if [[ $HOSTTYPE == *"x86_64"* ]]; then
                IDX=1
            elif [[ $HOSTTYPE == *"arm"* ]]; then
                IDX=2
            else
                message "The $HOSTTYPE  is not supported"
            fi
        ;;
        *)
            message "The \"$OSTYPE\" OS is not supported"
        ;;
    esac
    echo $IDX
}

dl() {
    DL_URL="${1}"
    OUTPUT="${TMP_DIR}/$(basename "$DL_URL")"
    shift

    case ${DL} in
        *"wget"*)
            wget --no-check-certificate --output-document="${OUTPUT}" "${DL_URL}";;
        *)
            ( cd "$TMP_DIR" && curl -JOL "$DL_URL" --silent );;
    esac
}

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") [-d directory] [-i IP/FQDN[,IP/FQDN]] [-p port] [M|H|N|A]
Setup monitoring packages for cnTools (Prometheus, Grafana, Node Exporter, and cnHids packages like OSSEC, Promtail, LOKI)
Depends on prereqs.sh.
-d directory      Top level directory where you'd like to deploy the packages for prometheus , node exporter, grafana, ossec etc
                      (default directory is /opt/cardano/monitoring)
-i IP/hostname    IPv4 address(es) or a FQDN/DNS name(s) where your cardano-node (relay/bpn) is running
                      (check for hasPrometheus in config.json on node; eg: 127.0.0.1 to make sure bound to 0.0.0.0 for remote monitoring)
                      to pass muliple nodes use , delimiter e.g -i relay1.domain,relay2.domain,bpn.domain
-p port           Port at which your cardano-node(s) is exporting stats (check for hasPrometheus in config.json; default=12798)
-[M|H|N|A]        Install specific configuration; performance (M)onitoring only, perf + cn(H)ids monitoring, (N)ode exporter, OSSEC (A)gent
                  (upgrade option to be added- preserve monitoring data)
                  Deployment patterns are: 1) Monitoring and agents installed on single cardano node (default),
                                           2) Install monitoring remotely and install agents on nodes.
                  We recommend installing monitoring on a seperate instance e.g. perf monitoring and HIDS connected to relay1 and bpn;
                      ./setup_mon.sh -H -i relay1.domain,bpn.domain
                  ...then install node exporter and OSSEC agents on relay1 and bpn cnode instances;
                      ./setup_mon.sh -NA
                  -M on remote server implies -N on nodes, -H on remote server implies -NA on nodes.
EOF
  exit 1
}

# General exit handler
cleanup () {
  [[ -n $1 ]] && err=$1 || err=$?
  [[ $err -eq 0 ]] && clear
  tput cnorm # restore cursor
  [[ -n ${exit_msg} ]] && echo -e "\n${exit_msg}\n" || echo -e "\nsetup_mon terminated, cleaning up...\n"
  $DBG rm -rf "$TMP_DIR"  #remove any tmp files
  tput sgr0  # turn off all attributes
  exit $err
}
trap cleanup HUP INT TERM
trap 'stty echo' EXIT

# Command     : myExit [exit code] [message]
# Description : gracefully handle an exit and restore terminal to original state
# Args        : 0=Clear terminal, 1+ Keep terminal state

myExit () {
  exit_msg="$2"
  cleanup "$1"
}

######################################################################
# Check variables and args
######################################################################

if [[ "${DEBUG}" == "Y" ]]; then
  DBG=echo
else
  unset DBG
fi

CURL=$(command -v curl)
WGET=$(command -v wget)
DL=${CURL:=$WGET}
if  [ -z "$DL" ]; then
    myExit 3 'You need to have "wget" or "curl" to be installed\nand accessable by PATH environment to continue...\nExiting.'
fi

[[ -z ${FORCE_OVERWRITE} ]] && FORCE_OVERWRITE='N'
[[ -z ${CNODE_NAME} ]] && CNODE_NAME='cnode'
[[ -z ${INTERACTIVE} ]] && INTERACTIVE='N'
[[ -z ${CURL_TIMEOUT} ]] && CURL_TIMEOUT=60
[[ -z ${UPDATE_CHECK} ]] && UPDATE_CHECK='Y'
[[ -z ${SUDO} ]] && SUDO='Y'
[[ "${SUDO}" = 'Y' ]] && sudo="sudo" || sudo=""
[[ "${SUDO}" = 'Y' && $(id -u) -eq 0 ]] && myExit 1 "Please run as non-root user."

# if using CNODE_HOME
# DOES THIS CHANGE IF WE USE ENV??
# Changes now CNODE_IP can be a comma delimited string
# We already exported these vars earlier!!! Check
if [[ -f "$CNODE_HOME/scripts/env" ]]; then
  CNODE_IP=$(jq -r .hasPrometheus[0] "$CONFIG" 2>/dev/null)
  CNODE_PORT=$(jq -r .hasPrometheus[1] "$CONFIG" 2>/dev/null)
  PROJ_PATH="$(cd "$CNODE_HOME/../monitoring 2>/dev/null";pwd)"
fi

while getopts :i:p:d:MHNA: opt; do
  case ${opt} in
    i )
      IFS=',' read -ra CNODE_IP <<< "$OPTARG"
      ;;
    p ) CNODE_PORT="$OPTARG" ;;
    d ) PROJ_PATH="$OPTARG" ;;
    M ) INSTALL_MON=true
        INSTALL_CNHIDS=false
        INSTALL_NODE_EXP=false
        INSTALL_OSSEC_AGENT=false
        ;;
    H ) INSTALL_CNHIDS=true
        INSTALL_MON=true
        INSTALL_NODE_EXP=false
        INSTALL_AGENT=false
        ;;
    N ) INSTALL_NODE_EXP=true
        INSTALL_CNHIDS=false
        INSTALL_MON=false
        ;;
    A )
        INSTALL_OSSEC_AGENT=true
        INSTALL_CNHIDS=false
        INSTALL_MON=false
        ;;
    \? )
      usage
      exit
      ;;
  esac
done
shift "$((OPTIND -1))"

## Test code- remove?
if [ "$INSTALL_MON" = true ] ; then
    echo 'INSTALL_MON = true'
fi

if [ "$INSTALL_CNHIDS" = true ] ; then
    echo 'INSTALL_CNHIDS = true'
fi

if [ "INSTALL_OSSEC_AGENT" = true ] ; then
    echo 'INSTALL_OSSEC_AGENT = true'
fi

if [ "INSTALL_NODE_EXP" = true ] ; then
    echo 'INSTALL_MON = true'
fi

echo 'CNODE_IP'
for i in "${CNODE_IP[@]}"; do
    echo "$i"
done

#exit

#######################################################
# Version Check                                       #
#######################################################

# Check if setup_mon.sh update is available
PARENT="$(dirname $0)"
if [[ ${UPDATE_CHECK} = 'Y' ]] && curl -s -f -m ${CURL_TIMEOUT} -o "${PARENT}"/setup_mon.sh.tmp ${URL_RAW}/scripts/cnode-helper-scripts/setup_mon.sh 2>/dev/null; then
  TEMPL_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/setup_mon.sh)
  TEMPL2_CMD=$(awk '/^# Do NOT modify/,0' "${PARENT}"/setup_mon.sh.tmp)
  if [[ "$(echo ${TEMPL_CMD} | sha256sum)" != "$(echo ${TEMPL2_CMD} | sha256sum)" ]]; then
    if get_answer "A new version of setup_mon script is available, do you want to download the latest version?"; then
      cp "${PARENT}"/setup_mon.sh "${PARENT}/setup_mon.sh_bkp$(date +%s)"
      STATIC_CMD=$(awk '/#!/{x=1}/^# Do NOT modify/{exit} x' "${PARENT}"/setup_mon.sh)
      printf '%s\n%s\n' "$STATIC_CMD" "$TEMPL2_CMD" > "${PARENT}"/setup_mon.sh.tmp
      {
        mv -f "${PARENT}"/setup_mon.sh.tmp "${PARENT}"/setup_mon.sh && \
        chmod 755 "${PARENT}"/setup_mon.sh && \
        myExit 0 "\nUpdate applied successfully, please run setup_mon again!\n"
      } || {
        myExit 1 "Update failed!\n\nPlease manually download latest version of setup_mon.sh script from GitHub"
      }
    fi
  fi
fi


#########################################
# Main
#########################################

#Check whether the install path already exists and exit if so (this needs to change once upgrade is supported)
if [ -e "$PROJ_PATH" ]; then
    myExit 1 "The \"$PROJ_PATH\" directory already exists please move or delete it.\nExiting."
fi

#Figure out what O/S variant we are running on (need to check which ones are supported for all packages)
IDX=$(get_idx)

#Trap ctrl+c etc for graceful exit (needs some more work on exit code)
trap myExit  SIGHUP SIGINT SIGQUIT SIGTRAP SIGABRT SIGTERM

# Set up directories for installation
PROM_DIR="$PROJ_PATH/prometheus"
GRAF_DIR="$PROJ_PATH/grafana"
PROMTAIL_DIR="$PROJ_PATH/promtail"
LOKI_DIR="$PROJ_PATH/loki"
OSSEC_METRICS_DIR="$PROJ_PATH/ossec_metrics"
NEXP_DIR="$PROJ_PATH/exporters"
DASH_DIR="$PROJ_PATH/dashboards"
SYSD_DIR="$PROJ_PATH/systemd"

# Create base directory and set permissions
echo "CREATE BASE DIRECTORY: Start"
mkdir -p "$PROJ_PATH" 2>/dev/null
rc=$?
if [[ "$rc" != 0 ]]; then
  echo "NOTE: Could not create directory as $(whoami), attempting sudo .."
  sudo mkdir -p "$PROJ_PATH" || message "WARN:Could not create folder $PROJ_PATH , please ensure that you have access to create it"
  sudo chown "$(whoami)":"$(id -g)" "$PROJ_PATH"
  chmod 750 "$PROJ_PATH"
  echo "NOTE: No worries, sudo worked !! Moving on .."
fi
echo "CREATE BASE DIRECTORY: End"

# Set up URLs for downloads
PROM_URL="https://github.com/prometheus/prometheus/releases/download/v$PROM_VER/prometheus-$PROM_VER.${ARCHS[IDX]}.tar.gz"
GRAF_URL="https://dl.grafana.com/oss/release/grafana-$GRAF_VER.${ARCHS[IDX]}.tar.gz"
NEXP_URL="https://github.com/prometheus/$NEXP/releases/download/v$NEXP_VER/$NEXP-$NEXP_VER.${ARCHS[IDX]}.tar.gz"
LOKI_URL="https://github.com/grafana/loki/releases/download/v$LOKI_VER/loki-${ARCHS[IDX]}.zip"
PROMTAIL_URL="https://github.com/grafana/loki/releases/download/v$PROMTAIL_VER/promtail-${ARCHS[IDX]}.zip"
OSSEC_URL="https://github.com/ossec/ossec-hids/archive/$OSSEC_VER.tar.gz"
OSSEC_METRICS_URL="https://github.com/slim-bean/ossec-metrics/archive/v$OSSEC_METRICS_VER.tar.gz"

echo ""
if [[ "$INSTALL_MON" = true ]]; then
   echo "INSTALL MONITORING: Start"
   PROM_SERVICE=true
   GRAF_SERVICE=true
   echo -e "Downloading base packages..." >&2
   echo -e "Downloading prometheus v$PROM_VER..." >&2
   $DBG dl "$PROM_URL"
   echo -e "Downloading grafana v$GRAF_VER..." >&2
   $DBG dl "$GRAF_URL"
   echo -e "Downloading grafana dashboard(s)..." >&2
   #Other dashboards are out of date...
   #echo -e "  - SKYLight Monitoring Dashboard" >&2
   #$DBG dl "$SKY_DB_URL"
   #echo -e "  - IOHK Monitoring Dashboard" >&2
   #$DBG dl "$IOHK_DB_URL"
   echo -e "  - ADAvault Monitoring Dashboard" >&2
   $DBG dl "$ADV_DB_URL"
   if [[ "$INSTALL_CNHIDS" = true ]]; then
      echo -e "  - cnHids Dashboard" >&2
      $DBG dl "CNHIDS_DB_URL"
   fi

   echo -e "Configuring components" >&2
   # Create install dirs
   mkdir -p "$PROM_DIR" "$GRAF_DIR" "$DASH_DIR" "$SYSD_DIR"
   # Untar files (strip leading component of path)
   tar zxC "$PROM_DIR" -f "$TMP_DIR"/*prome*gz --strip-components 1
   tar zxC "$GRAF_DIR" -f "$TMP_DIR"/*graf*gz --strip-components 1
   # Add install code here
   # Get tokenised conf files from Github, and replace tokens
   # Setup Grafana config- register datasource
   echo "Registering Prometheus as datasource in Grafana.."
   $DBG dl "$GRAF_CONF_URL"
   sed -i "s+localhost:8080+$PROM_HOST:$PROM_PORT+" "$TMP_DIR"/grafana-datasources.yaml
   cp "$TMP_DIR"/grafana-datasources.yaml "$GRAF_DIR"//conf/provisioning/datasources/grafana-datasources.yaml
   # Fix grafana's datasource in dashboards
   sed -e "s#Prometheus#prometheus#g" "$TMP_DIR"/*.json -i
   cp -pr "$TMP_DIR"/*.json "$DASH_DIR/"
   #Fix grafana hostname reference in default.ini
   #Add extra default.ini fixes here
   HOSTNAME=$(hostname)
   sed -e "s/http_addr.*/http_addr = $GRAFANA_HOST/g" -e "s/http_port = 3000/http_port = $GRAFANA_PORT/g" "$GRAF_DIR"/conf/defaults.ini -i

#RW 02032021 Replace with tokenised yml below...needs loop for multiple targets
#   sed -e "s#\(^scrape_configs:.*\)#\1\n\
#  - job_name: '${HOSTNAME}_cardano_node'\n\
#    static_configs:\n\
#    - targets: ['$CNODE_IP:$CNODE_PORT']\n\
#  - job_name: '${HOSTNAME}_node_exporter'\n\
#    static_configs:\n\
#    - targets: ['$CNODE_IP:$NEXP_PORT']#g" -e "s#localhost:9090#$PROM_HOST:$PROM_PORT#g" "$PROM_DIR"/prometheus.yml -i

   # Setup Prometheus config...append to conf file
   $DBG dl "$PROM_CONF_URL"
#Loop for multiple nodes
for i in "${CNODE_IP[@]}"; do
cat >> "$TMP_DIR"/prometheus.yml <<EOF
  - job_name: '${i}_cardano_node'
    static_configs:
    - targets: ['$i:$CNODE_PORT']
  - job_name: '${i}_node_exporter'
    static_configs:
    - targets: ['$i:$NEXP_PORT']
EOF
done
   #Check to see if we need add scrapes for cnHids
   if [[ "$INSTALL_CNHIDS" = true ]]; then
   cat >> "$TMP_DIR"/prometheus.yml <<EOF
  - job_name: 'ossec'
    static_configs:
    - targets: ['localhost:8080']
  - job_name: 'ossec-metrics'
    static_configs:
    - targets: ['localhost:7070']
  - job_name: 'loki'
    static_configs:
    - targets: ['localhost:3100']
EOF
   fi
   cp "$TMP_DIR"/prometheus.yml "$PROM_DIR"

   # Change icons - change these to your icons, example for ADAvault
   # Add code here

#provision the dashboards
cat > "$GRAF_DIR"/conf/provisioning/dashboards/guildops.yaml <<EOF
# config file version
apiVersion: 1

providers:
 - name: 'GuildOps'
   orgId: 1
   folder: ''
   folderUid: ''
   type: file
   options:
     path: $DASH_DIR
EOF
   echo "INSTALL MONITORING: End"
fi

#Fetch OSSEC for cnHids server and agents installs
if [[ "$INSTALL_CNHIDS" = true || "$INSTALL_OSSEC_AGENTS" = true ]] ; then
   echo "INSTALL CNHIDS SERVER: Start"
   #prereqs for OSSEC- move into prereqs?
   sudo apt install gcc make libevent-dev zlib1g-dev libssl-dev libpcre2-dev wget tar unzip -y
   echo -e "Downloading OSSEC server/agent" >&2
   $DBG dl "$OSSEC_URL"
   # Create install dirs NOT NEEDED FOR OSSEC?
   #mkdir -p "$OSSEC_DIR"
   # Add install code here for OSSEC
   # Is it possible to remove the manual choices? Can we provide an answer file?
   # For now we just launch
   tar xzf 3.6.0.tar.gz
   tar zxC "$TMP_DIR" -f "$TMP_DIR"/v"$OSSEC_VER"*gz --strip-components 1
   cd "$TMP_DIR"
   sudo ./install.sh
   #Follow the prompts to install server version of OSSEC
   #Work out how to automate later...
   #Configure the ossec.conf- for now we just get the file and copy across
   #sudo perl -0777 -pe 's/<global>.*?</global>/STRING3/gs' /var/ossec/etc/ossec.conf
   #sed 's/\(.*|<global>|\).*\(|STRING3|.*\)/\1</global>\2/' /var/ossec/etc/ossec.conf > /var/ossec/etc/ossec.conf
   $DBG dl "$OSSEC_CONF_URL"
   sudo cp "$TMP_DIR"/ossec.conf /var/ossec/etc/ossec.conf
   sudo /var/ossec/bin/ossec-control restart
    echo "INSTALL CNHIDS SERVER: End"
fi

if [[ "$INSTALL_CNHIDS" = true ]] ; then
   echo "INSTALL CNHIDS DEPENDENCIES: Start"
   PROMTAIL_SERVICE=true
   LOKI_SERVICE=true
   OSSEC_METRICS_SERVICE=true
   echo -e "Downloading cnHids packages..." >&2
   $DBG dl "$PROMTAIL_URL"
   $DBG dl "$LOKI_URL"
   $DBG dl "$OSSEC_METRICS_URL"

   echo -e "Configuring components" >&2
   # Create install dirs
   mkdir -p "$PROMTAIL_DIR" "$LOKI_DIR" "$OSSEC_METRICS_DIR"
   # Unzip files (strip leading component of path)
   unzip -d "$PROMTAIL_DIR" "$TMP_DIR"/*promta*zip && f=("$PROMTAIL_DIR"/*) && mv "$PROMTAIL_DIR"/*/* "$PROMTAIL_DIR" && rmdir "${f[@]}"
   unzip -d "$LOKI_DIR" "$TMP_DIR"/*loki*zip && f=("$LOKI_DIR"/*) && mv "$LOKI_DIR"/*/* "$LOKI_DIR" && rmdir "${f[@]}"
   tar zxC "$TMP_DIR" -f "$TMP_DIR"/v"$OSSEC_METRICS_VER"*gz --strip-components 1

   # Set as executable
   chmod +x "$PROMTAIL_DIR"/promtail-linux-amd64
   # Get tokenised conf files from Github, and replace tokens
   # Promtail
   $DBG dl "$PROMTAIL_CONF_URL"
   sed -i 's+Europe/London+"$TIMEZONE"+' "$TMP_DIR"/$(basename "$PROMTAIL_CONF_URL")
   cp "$TMP_DIR"/$(basename "$PROMTAIL_CONF_URL") "$PROMTAIL_DIR"
   # Loki
   $DBG dl "$LOKI_CONF_URL"
   sed -i 's+/opt/cardano/monitoring+"$PROJ_PATH"+g' "$TMP_DIR"/$(basename "$LOKI_CONF_URL")
   cp "$TMP_DIR"/$(basename "$LOKI_CONF_URL") "$LOKI_DIR"
   # OSSEC-metrics
   sudo apt install golang-go
   cd "$TMP_DIR"/ossec-metrics-"$OSSEC_METRICS_VER"/
   go build -o ossec-metrics cmd/ossec-metrics/main.go
   chmod +x ossec-metrics
   mv ossec-metrics "$OSSEC_METRICS_DIR"
   echo "INSTALL CNHIDS DEPENDENCIES: End"
fi

if [[ "$INSTALL_NODE_EXP" = true ]] ; then
   echo "INSTALL NODE EXPORTER: Start"
   NEXP_SERVICE=true
   echo -e "Downloading exporter v$NEXP_VER..." >&2
   $DBG dl "$NEXP_URL"

   echo -e "Configuring components" >&2
   # Create install dirs
   mkdir -p "$NEXP_DIR" "$SYSD_DIR"
   # Untar files (strip leading component of path)
   tar zxC "$TMP_DIR" -f "$TMP_DIR"/*node_exporter*gz --strip-components 1
   # Move to destination and set as executable
   mv "$TMP_DIR/node_exporter" "$NEXP_DIR/"
   chmod +x "$NEXP_DIR"/*
   # Add install code here
   # Get tokenised conf files from Github, and replace tokens 
   echo "INSTALL NODE EXPORTER: End"
fi


##########################################
# Set up the service definitions
##########################################

#Promtail start --->
if [[ "$PROMTAIL_SERVICE" = true ]] ; then
echo "INSTALL PROMTAIL SERVICE: Start"
cat > "$SYSD_DIR"/promtail.service <<EOF
[Unit]
Description=Promtail Loki Agent
After=loki.service

[Service]
Type=simple
User=root
ExecStart=$PROMTAIL_DIR/promtail-linux-amd64 -config.file promtail.yaml
WorkingDirectory=$PROMTAIL_DIR
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

#Copy over the files and start services
echo "Creating Promtail service definitions as root..."
sudo cp "$SYSD_DIR"/promtail.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable promtail
sudo systemctl start promtail
echo "INSTALL PROMTAIL SERVICE: End"
fi
#<---Promtail end

#LOKI start --->
if [[ "$LOKI_SERVICE" = true ]] ; then
echo "INSTALL LOKI SERVICE: Start"
cat > "$SYSD_DIR"/loki.service <<EOF
[Unit]
Description=Loki Log Aggregator
After=network.target

[Service]
Type=simple
User=cnhids
ExecStart=$LOKI_DIR/loki-linux-amd64 -config.file loki-config.yaml
WorkingDirectory=$LOKI_DIR
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

#Copy over the files and start services
echo "Creating loki service definitions as root..."
sudo cp "$SYSD_DIR"/loki.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable loki
sudo systemctl start loki
echo "INSTALL LOKI SERVICE: End"
fi
#<---LOKI end

#OSSEC_METRICS start --->
if [[ "$OSSEC_METRICS_SERVICE" = true ]] ; then
echo "INSTALL OSSEC_METRICS SERVICE: Start"
cat > "$SYSD_DIR"/ossec-metrics.service <<EOF
[Unit]
Description=Ossec Metrics exposes OSSEC info for prometheus to scrape
After=network.target

[Service]
Type=simple
User=root
ExecStart=$OSSEC_METRICS_DIR/ossec-metrics
WorkingDirectory=$OSSEC_METRICS
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

#Copy over the files and start services
echo "Creating ossec-metrics service definitions as root..."
sudo cp "$SYSD_DIR"/ossec-metrics.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable ossec-metrics
sudo systemctl start ossec-metrics
echo "INSTALL OSSEC_METRICS SERVICE: End"
fi
#<---OSSEC_METRICS end

#Prometheus start --->
if [[ "$PROM_SERVICE" = true ]] ; then
echo "INSTALL PROMETHEUS SERVICE: Start"
cat > "$SYSD_DIR"/prometheus.service <<EOF
[Unit]
Description=Prometheus Server
Documentation=https://prometheus.io/docs/introduction/overview/
After=network-online.target

[Service]
User=$(whoami)
Restart=on-failure
ExecStart=$PROM_DIR/prometheus \
  --config.file=$PROM_DIR/prometheus.yml \
  --storage.tsdb.path=$PROM_DIR/data --web.listen-address=$PROM_HOST:$PROM_PORT
WorkingDirectory=$PROM_DIR
LimitNOFILE=10000

[Install]
WantedBy=multi-user.target
EOF

#Copy over the files and start services
echo "Creating Prometheus service definitions as root..."
sudo cp "$SYSD_DIR"/prometheus.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable prometheus
sudo systemctl start prometheus
echo "INSTALL PROMETHEUS SERVICE: End"
fi
#<---Prometheus end

#Node Exporter --->
if [[ "$NEXP_SERVICE" = true ]] ; then
echo "INSTALL NODE EXPORTER SERVICE: Start"
cat > "$SYSD_DIR"/node-exporter.service <<EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=$(whoami)
Restart=on-failure
ExecStart=$NEXP_DIR/node_exporter --web.listen-address="$CNODE_IP:$NEXP_PORT"
WorkingDirectory=$NEXP_DIR
LimitNOFILE=3500

[Install]
WantedBy=default.target
EOF

#Copy over the files and start services
echo "Creating Node exporter service definitions as root..."
sudo cp "$SYSD_DIR"/node-exporter.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable node-exporter
sudo systemctl start node-exporter
echo "INSTALL NODE EXPORTER SERVICE: End"
fi
#<---Node Exporter end

#Grafana start --->
if [[ "$GRAF_SERVICE" = true ]] ; then
echo "INSTALL GRAFANA SERVICE: Start"
cat > "$SYSD_DIR"/grafana.service <<EOF
[Unit]
Description=Grafana instance
Documentation=http://docs.grafana.org
Wants=network-online.target
After=network-online.target

[Service]
User=$(whoami)
Restart=on-failure
ExecStart=$GRAF_DIR/bin/grafana-server web
WorkingDirectory=$GRAF_DIR
LimitNOFILE=10000

[Install]
WantedBy=default.target
EOF

#Copy over the files and start services
echo "Creating Grafana service definitions as root..."
sudo cp "$SYSD_DIR"/grafana.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable grafana
sudo systemctl start grafana
echo "INSTALL GRAFANA SERVICE: End"
fi
#<---Grafana end


#############################################
# Finish the install
#############################################

#Make the output conditional based on what was selected

echo -e "
=====================================================
Installation is completed
=====================================================
" >&2

if [[ "$INSTALL_MON" = true ]]; then
echo -e "
- Prometheus (default): http://$PROM_HOST:$PROM_PORT/metrics
- Grafana (default):    http://$IP_ADDRESS:$GRAFANA_PORT
You need to do the following to configure grafana:
0. The services should already be started, verify if you can login to grafana, and prometheus. If using 127.0.0.1 as IP, you can check via curl
1. Login to grafana as admin/admin (http://$IP_ADDRESS:$GRAFANA_PORT)
2. Add \"prometheus\" (all lowercase) datasource (http://$PROM_HOST:$PROM_PORT)
3. Create a new dashboard by importing dashboards (left plus sign).
  - Sometimes, the individual panel's \"prometheus\" datasource needs to be refreshed.
" >&2
fi

if [[ "$INSTALL_NODE_EXP" = true ]]; then
echo -e "
- Node metrics:       http://$CNODE_IP:$CNODE_PORT
- Node exp metrics:   http://$CNODE_IP:$NEXP_PORT
" >&2
fi

myExit 1 "END: Thanks for watching. This has been a GuildOps Production."

