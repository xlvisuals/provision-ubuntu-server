#!/bin/bash
#
# UBUNTU 24.04 and 26.04 SERVER PROVISIONING SCRIPT
# by Xlvisuals Limited
# 30 April 2026
# -----------------------------------------------------------------------------------------
#
# Usage: sudo bash ubuntu_provision.sh [ubuntu_provision.conf]
# See README.md for full documentation.
#
# PREREQUISITES:
#   - Ubuntu 24.04 or 26.04 Server (minimized or standard)
#   - Internet connection
#   - 8 GB disk space for minimized, 12 GB for standard (+swap)
#
# INSTALLS (all optional):
#   - Web stack:    Nginx, MySQL, PostgreSQL, Valkey, Mosquitto
#   - Mail:         Postfix (relay-only; Monit, Grafana, Forgejo can route through it)
#   - Management:   Webmin, Monit, Grafana, Forgejo
#   - Runtimes:     Python 3.14, PyPy 3.11, Weasyprint, ImageMagick
#   - Security:     UFW, Fail2Ban, Suricata, auditd, Wazuh Agent, IP blocklist
#   - Tools:        vim, nano, micro, ne, tmux, btop, ncdu, rsync, dnsutils,
#                   nmap, lynis, git, git-lfs, jq, smartmontools (bare metal only)
#
# MODIFIES (all optional):
#   - System:   LVM resize, swap file, file limits, kernel tuning (sysctl)
#   - Security: SSH hardening (key-only), UFW rules, sudo timeout/NOPASSWD
#   - Timers:   Unattended-upgrades scheduled at prompted UTC hours
#   - User:     Creates or configures a sudo user, sets up SSH key access


## Set package versions and other defaults (or in .conf file)
## --------------------------------------------

PG_VERSION="18"
PYPY_VERSION="pypy3.11-v7.3.21-linux64"

FORGEJO_FALLBACK_PORT="3030"

## Checks and Utilities
## --------------------------------------------


# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

# Verify Ubuntu 24.04 or 26.04
source /etc/os-release
if [[ "$ID" != "ubuntu" || !("$VERSION_ID" == "24.04" || "$VERSION_ID" == "26.04" ) ]]; then
    echo "Error: This script is intended for Ubuntu 24.04 and 26.04"
    exit 1
fi

# Read config file if provided
if [[ -n "$1" ]]; then
    if [[ -f "$1" ]]; then
        echo "Loading configuration from $1"
        source "$1"
    else
        echo "Error: config file '$1' not found."
        exit 1
    fi
fi
# If INSTALL_DEFAULT is set, apply INSTALL_DEFAULT to any INSTALL_ and CONFIGURE_ variable not explicitly set in conf
if [[ -n "${INSTALL_DEFAULT:-}" ]]; then
    for var in \
        INSTALL_UFW INSTALL_SSH INSTALL_FONTS INSTALL_WEASYPRINT INSTALL_IMAGEMAGICK \
        INSTALL_CPYTHON314 INSTALL_PYPY311 INSTALL_NGINX INSTALL_VALKEY INSTALL_MYSQL \
        INSTALL_POSTGRESQL INSTALL_MOSQUITTO INSTALL_POSTFIX INSTALL_MONIT INSTALL_WEBMIN \
        INSTALL_GRAFANA INSTALL_FORGEJO INSTALL_FAIL2BAN INSTALL_AUDITD INSTALL_IPBLOCK \
        INSTALL_SURICATA INSTALL_WAZUH; do
        [[ -z "${!var:-}" ]] && printf -v "$var" "$INSTALL_DEFAULT"
    done
    for var in CONFIGURE_LVM CONFIGURE_SWAP CONFIGURE_APPARMOR TUNE_SYSTEM \
               UNINSTALL_PACKAGES UPDATE_PACKAGES INSTALL_PACKAGES \
               DISABLE_TX_OFFLOAD; do
        [[ -z "${!var:-}" ]] && printf -v "$var" "$INSTALL_DEFAULT"
    done
fi

# change into current directory
cd "$(dirname "$(readlink -f "$0")")" || exit

# Config files are expected in the etc subdirectory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR"

# Exit when any command fails silently
set -Eeuo pipefail

save_config() {
    if [[ "${1:-}" ]]; then
        config_output_file=$1
    else
        config_output_file="provision_$(date +%F_%H%M%S).conf"
    fi
    set | grep -E "^(INSTALL_|CONFIGURE_|MYSQL_|PG_|POSTFIX_|MONIT_|GRAFANA_|FORGEJO_|WAZUH_|NGINX_|APPARMOR_|APT_|DISABLE_|LVM_|SWAP_|TUNE_|UNINSTALL_|UPDATE_|USER_|PROMPT_|LOCAL_)" \
        | grep -v "PASSWORD\|PASS\|SECRET" \
        > $config_output_file
    echo "Configuration parameters written to '$config_output_file'. "
}

# Easier debugging

on_error() {
    local exit_code=$?
    local line="$1"
    set +e
    trap - ERR EXIT
    if [[ $exit_code -ne 0 ]]; then
        config_debug_file="provision_debug.conf"
        echo ""
        echo "Error: Script failed at line $line (exit code $exit_code) — dumping variables to file"
        save_config "$config_debug_file"
        echo ""
        echo "Run 'sudo bash ubuntu_provision.sh $config_debug_file' if you want to continue with these settings."
        echo ""
    fi
    exit $exit_code
}


#trap 'echo "ERROR on line $LINENO"' ERR
trap 'on_error $LINENO' ERR

# Prevents any apt prompts from breaking the script.
export DEBIAN_FRONTEND=noninteractive

# auto-confirm and faster installs
APT_FLAGS="-y -o Dpkg::Use-Pty=0"


# helper functions

check_service() {
    local service="$1"
    local var="$2"
    local installed_var="${3:-}"

    if systemctl status "$service" &>/dev/null; then
        echo "- $service is already installed"
        printf -v "$var" "reinstall"
        [[ -n "$installed_var" ]] && printf -v "$installed_var" "y"
    else
        echo "- $service is NOT installed"
        printf -v "$var" "install"
        [[ -n "$installed_var" ]] && printf -v "$installed_var" "n"
    fi
}

check_file() {
    local filepath="$1"
    local filename=$(basename ${filepath})
    local var="$2"

    if [[ -f "$filepath" ]] ; then
        echo "- $filename is installed"
        printf -v "$var" "reinstall"
    else
        echo "- $filename is NOT installed"
        printf -v "$var" "install"
    fi
}

wait_for_apt() {
  while lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || lsof /var/lib/dpkg/lock >/dev/null 2>&1 \
     || lsof /var/lib/apt/lists/lock >/dev/null 2>&1 \
     || lsof /var/cache/apt/archives/lock >/dev/null 2>&1; do
    sleep 2
  done
}

prompt_if_unset() {
    local varname="$1"
    local prompt="$2"
    local silent="${3:-n}"
    local default="${4:-}"

    # The - (with no default value) tells bash to return an empty string if the variable is unset
    if [[ -z "${!varname-}" ]]; then
        if [[ "$silent" == "secret" ]]; then
            read -rsp "$prompt : " "$varname"; echo ""
        else
            if [[ -n "$default" ]]; then
                read -rp "$prompt [$default]: " "$varname"
                # If user just hit Enter, use the default
                if [[ -z "${!varname}" ]]; then
                    printf -v "$varname" '%s' "$default"
                fi
            else
                read -rp "$prompt : " "$varname"
            fi
        fi
    else
        # variable is set, print it
        if [[ "$silent" == "secret" ]]; then
            echo "$prompt : [set]";
        else
          echo "$prompt : ${!varname}";
        fi
    fi
}

mysql_root() {
    local defaults_file=$(mktemp)
    chmod 600 "$defaults_file"
    echo -e "[client]\npassword=$MYSQL_PASS" > "$defaults_file"
    if mysql -u root "$@" 2>/dev/null; then
        rm -f "$defaults_file"
        return 0
    else
        mysql --defaults-extra-file="$defaults_file" -u root "$@"
        local exit_code=$?
        rm -f "$defaults_file"
        return $exit_code
    fi
}

# LOGGING SETUP
LOG_FILE="/var/log/ubuntu_provision_$(date +%F_%H%M%S).log"
# Use 'exec' to redirect STDOUT and STDERR through 'tee'
# This captures EVERYTHING that follows into the log file.
exec > >(tee -a "$LOG_FILE") 2>&1


## Main
## --------------------------------------------


echo "Xlvisuals Ubuntu LTS server provisioning"
echo "Provisioning started: $(date)"
echo "Logging to: $LOG_FILE"

echo "Stopping unattended upgrades"
systemctl stop apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer

# Detect network IP, just for logging
echo "--- 1. Detecting network and system parameters  ---"

# Set system related variables

PROCESSOR_COUNT=$(nproc)
# Get hostname and ip address
LOCAL_HOSTNAME=$(hostname -f)
LOCAL_IP=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+')
# Detect the calling user
REAL_USER=${SUDO_USER:-$(logname 2>/dev/null)}
USER_SUDO_USER_USERNAME=""

# Detect network interface
# PRIMARY_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
# PRIMARY_INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
PRIMARY_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$PRIMARY_INTERFACE" ]; then
    echo "Error: Could not detect network interface"
    exit 1
fi
echo "Detected network interface: $PRIMARY_INTERFACE"


PRIMARY_IP=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+')
echo "Detected network address: $PRIMARY_IP"

# Verify we have internet. Fails on Ubuntu minimized as no iputils-ping package, fall back to python
NETWORK_OK=''
if command -v ping &>/dev/null; then
    ping -c1 -W2 1.1.1.1 &>/dev/null && NETWORK_OK=y || NETWORK_OK=n
else
    python3 -c "import socket,sys; s=socket.socket(); s.settimeout(2); s.connect(('1.1.1.1',53)); s.close(); sys.exit(0)" \
        2>/dev/null && NETWORK_OK=y || NETWORK_OK=n
fi
if [[ "$NETWORK_OK" == "n" ]]; then
    echo "Error: No internet connection"
    exit 1
fi

echo ""
echo "--- 2. Configure new installation ---"

echo "Determining installed python:"
check_file /usr/bin/python3.12 PROMPT_CPYTHON312
check_file /usr/bin/python3.13 PROMPT_CPYTHON313
check_file /usr/bin/python3.14 PROMPT_CPYTHON314
check_file /usr/local/bin/pypy3.9 PROMPT_PYPY39
check_file /usr/local/bin/pypy3.10 PROMPT_PYPY310
check_file /usr/local/bin/pypy3.11 PROMPT_PYPY311
echo "Determining installed programs:"
check_file /usr/bin/weasyprint PROMPT_WEASYPRINT
check_file /usr/bin/convert PROMPT_IMAGEMAGICK

echo "Determining installed services:"
check_service nginx PROMPT_NGINX ISINSTALLED_NGINX
check_service valkey-server PROMPT_VALKEY ISINSTALLED_VALKEY
check_service mysql PROMPT_MYSQL ISINSTALLED_MYSQL
check_service postgresql PROMPT_POSTGRESQL ISINSTALLED_POSTGRESQL
check_service mosquitto PROMPT_MOSQUITTO ISINSTALLED_MOSQUITTO
check_service postfix PROMPT_POSTFIX ISINSTALLED_POSTFIX
check_service monit PROMPT_MONIT ISINSTALLED_MONIT
check_service webmin PROMPT_WEBMIN ISINSTALLED_WEBMIN
check_service grafana-server PROMPT_GRAFANA ISINSTALLED_GRAFANA
check_service forgejo PROMPT_FORGEJO ISINSTALLED_FORGEJO
check_service fail2ban PROMPT_FAIL2BAN ISINSTALLED_FAIL2BAN
check_service auditd PROMPT_AUDITD ISINSTALLED_AUDITD
check_service suricata PROMPT_SURICATA ISINSTALLED_SURICATA
check_service wazuh-agent PROMPT_WAZUH ISINSTALLED_WAZUH

# Detect AppArmor state
APPARMOR_INSTALLED=n
APPARMOR_ENABLED=n
APPARMOR_CURRENT_MODE="complain"
if command -v aa-status &>/dev/null; then
    APPARMOR_INSTALLED=y
    if aa-status --enabled 2>/dev/null; then
        APPARMOR_ENABLED=y
        if aa-status 2>/dev/null | grep -q "profiles are in enforce mode"; then
            APPARMOR_CURRENT_MODE="enforce"
        else
            APPARMOR_CURRENT_MODE="complain"
        fi
    fi
fi


if [[ -f /etc/cron.daily/ufw-blocklist-ipsum && -s /etc/cron.daily/ufw-blocklist-ipsum ]]; then
    echo "- IP blocklist is already installed"
    PROMPT_IPBLOCK="reinstall"
else
    PROMPT_IPBLOCK="install"
fi


## Prompt for configuration if not using .conf
## --------------------------------------------

echo ""
echo "Configure installation options:"

## user
prompt_if_unset USER_CREATE_SUDO_USER "Would you like to add a new sudo user? (y/n)" n "n"
if [[ "$USER_CREATE_SUDO_USER" =~ ^[Yy]$ ]]; then
    # Interactive username host prompt
    while true; do
        #read -p "                                Enter username : " USER_SUDO_USER_USERNAME
        prompt_if_unset USER_SUDO_USER_USERNAME "Enter username" n
        echo
        if [[ ${#USER_SUDO_USER_USERNAME} -ge 4 ]]; then
            break
        fi
    done
else
    # If run via sudo, offer the current user as the default
    if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
        #read -p "Use current user '$REAL_USER' for setup?    (y/n)" USER_USE_CURRENT_USERNAME
        prompt_if_unset USER_USE_CURRENT_USERNAME "Use current user '$REAL_USER'?         (y/n)" n "y"
        if [[ "$USER_USE_CURRENT_USERNAME" =~ ^[Yy]$ || -z "$USER_USE_CURRENT_USERNAME" ]]; then
            USER_SUDO_USER_USERNAME=$REAL_USER
        fi
    fi

    # Ask manually if not using sudo or not wanting current user
    if [[ -z "$USER_SUDO_USER_USERNAME" ]]; then
        while true; do
            #read -p "                  Enter existing sudo username : " USER_SUDO_USER_USERNAME
            prompt_if_unset USER_SUDO_USER_USERNAME "Enter existing sudo username" n
            if [[ ${#USER_SUDO_USER_USERNAME} -ge 4 ]]; then
                break
            fi
            echo "Username must be at least 4 characters."
        done
    fi
fi
if [[ -z "$USER_SUDO_USER_USERNAME" ]]; then
	# Final Check
    echo "Error: We need a sudo user to complete the setup."
    exit 1
fi

## LVM
prompt_if_unset CONFIGURE_LVM "Would you like to configure LVM disks? (y/n)" n "n"
if [[ "$CONFIGURE_LVM" =~ ^[Yy]$ ]]; then
    # 1. Check if the logical volume exists
    # 2. Check if the Volume Group has more than 0 free space
    VG_NAME="ubuntu-vg"
    LV_PATH="/dev/ubuntu-vg/ubuntu-lv"

    if lvs "$LV_PATH" &>/dev/null; then
        LVM_FREE_SPACE=$(vgs "$VG_NAME" --noheadings -o vg_free_count | xargs)
        # Convert extents to approximate GB (assuming 4MB extents)
        LVM_FREE_GB=$(vgs "$VG_NAME" --noheadings --units g -o vg_free | xargs | tr -d 'g')

        if [ "$LVM_FREE_SPACE" -gt 0 ]; then
            echo "  LVM detected. Free space in Volume Group: ${LVM_FREE_GB}GB"
            prompt_if_unset LVM_DO_RESIZE "  Resize root LVM? (y/n)" n "n"
            if [[ "$LVM_DO_RESIZE" =~ ^[Yy]$ ]]; then
                prompt_if_unset LVM_TARGET_GB "  Enter target size in GB (or type 'all')" n "all"
            fi
        else
            echo "  LVM detected, but no free space remains in Volume Group. Skipping."
        fi
    else
        echo "  Logical Volume $LV_PATH not found (System may not use LVM). Skipping."
    fi
fi

## SWAP
ACTIVE_SWAP=''
prompt_if_unset CONFIGURE_SWAP "Would you like to configure swap space? (y/n)" n "n"
if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ ]]; then
    CURRENT_SWAP_ACTIVE=$(tail -n +2 /proc/swaps)
    if [ -z "$CURRENT_SWAP_ACTIVE" ]; then
    	ACTIVE_SWAP='No'
        echo "  No active swap detected."
        prompt_if_unset CONFIGURE_SWAP "  Would you like to create a swap file? (y/n)" n "all"
        if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ ]]; then
            prompt_if_unset SWAP_SIZE_GB "  Enter swap size in GB" n "2"
        fi
    else
    	ACTIVE_SWAP='Yes'
        echo "  Active swap detected. No changes."
    fi
fi

prompt_if_unset TUNE_SYSTEM "Would you like to tune the system? (y/n)" n "n"
if [[ "$TUNE_SYSTEM" =~ ^[Yy]$ ]]; then
    while true; do
        prompt_if_unset APT_DAILY_HOUR "  Hour to run apt-get update (0-23)" n "10"
        if [[ "$APT_DAILY_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
            break
        fi
        APT_DAILY_HOUR=''
        echo "  Invalid hour. Please enter a number between 0 and 23."
    done
    # apt-daily (fetch) runs twice daily, 12 hours apart
    APT_DAILY_HOUR_2=$(( (APT_DAILY_HOUR + 12) % 24 ))
    while true; do
        prompt_if_unset APT_UPGRADE_HOUR "  Hour to run apt-get upgrade (0-23)" n "$(( (APT_DAILY_HOUR + 1) % 24 ))"
        if [[ "$APT_UPGRADE_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
            break
        fi
        APT_UPGRADE_HOUR=''
        echo "  Invalid hour. Please enter a number between 0 and 23."
    done
fi

prompt_if_unset UNINSTALL_PACKAGES "Would you like to uninstall packages? (y/n)" n "n"

prompt_if_unset UPDATE_PACKAGES "Would you like to update packages? (y/n)" n "n"

prompt_if_unset INSTALL_PACKAGES "Would you like to install new packages? (y/n)" n "n"

prompt_if_unset INSTALL_UFW "Would you like to configure ufw? (y/n)" n "n"

prompt_if_unset INSTALL_SSH "Would you like to configure ssh? (y/n)" n "n"

prompt_if_unset INSTALL_FONTS "Would you like to install fonts? (y/n)" n "n"
if [[ "$INSTALL_FONTS" =~ ^[Yy]$ ]]; then
    prompt_if_unset INSTALL_MS_FONTS "   Install Microsoft core fonts? (y/n)" n "y"
fi

prompt_if_unset INSTALL_WEASYPRINT "Would you like to $PROMPT_WEASYPRINT weasyprint? (y/n)" n "n"

prompt_if_unset INSTALL_IMAGEMAGICK "Would you like to $PROMPT_IMAGEMAGICK imagemagick? (y/n)" n "n"

prompt_if_unset INSTALL_CPYTHON314 "Would you like to $PROMPT_CPYTHON314 Python 3.14? (y/n)" n "n"

prompt_if_unset INSTALL_PYPY311 "Would you like to $PROMPT_PYPY311 Pypy 3.11? (y/n)" n "n"

prompt_if_unset INSTALL_NGINX "Would you like to $PROMPT_NGINX nginx? (y/n)" n "n"
if [[ "$INSTALL_NGINX" =~ ^[Yy]$ ]]; then
  prompt_if_unset NGINX_WORKER_PROCESSES "  nginx worker processes?" n "$PROCESSOR_COUNT"
fi

prompt_if_unset INSTALL_VALKEY "Would you like to $PROMPT_VALKEY valkey? (y/n)" n "n"

prompt_if_unset INSTALL_MYSQL "Would you like to $PROMPT_MYSQL MySQL? (y/n)" n "n"
if [[ "$INSTALL_MYSQL" =~ ^[Yy]$ ]]; then
    # Interactive Password Prompt
    while true; do
        prompt_if_unset MYSQL_PASS         "  MySQL root password" secret
        if [ "${#MYSQL_PASS}" -ge 4 ]; then
            break
        fi
        MYSQL_PASS=''
        echo "  Password is too short. Must be at least 4 characters."

#        prompt_if_unset MYSQL_PASS_CONFIRM "  MySQL root password (confirm)" secret
#        if [ "$MYSQL_PASS" == "$MYSQL_PASS_CONFIRM" ] && [ "${#MYSQL_PASS}" -ge 4 ]; then
#            break
#        elif [ "${#MYSQL_PASS}" -lt 4 ]; then
#            MYSQL_PASS=''
#            MYSQL_PASS_CONFIRM=''
#            echo "  Password is too short. Must be at least 4 characters."
#        else
#            MYSQL_PASS=''
#            MYSQL_PASS_CONFIRM=''
#            echo "  Passwords do not match. Please try again."
#        fi
    done
    # Escape for SQL, including ' " \ $
    MYSQL_PASS_ESCAPED=$(printf "%s" "$MYSQL_PASS" | sed "s/'/''/g")

    # Get chunk size first - pool size must be a multiple of it
    prompt_if_unset MYSQL_BUFFER_POOL_CHUNK_MB "  InnoDB buffer pool chunk size (MB)" n "128"
    MYSQL_BUFFER_POOL_MB="${MYSQL_BUFFER_POOL_MB:-}"

    # Only auto-calculate pool size if not set in conf file
    if [[ -z "$MYSQL_BUFFER_POOL_MB" ]]; then
        TOTAL_MEM_MB=$(free -m | awk '/^Mem:/ {print $2}')
        BUFFER_POOL_MB=$(( TOTAL_MEM_MB * 30 / 100 ))
        # Round down to nearest multiple of chunk size
        BUFFER_POOL_MB=$(( (BUFFER_POOL_MB / MYSQL_BUFFER_POOL_CHUNK_MB) * MYSQL_BUFFER_POOL_CHUNK_MB ))
        # Need at least one chunk
        if (( BUFFER_POOL_MB < MYSQL_BUFFER_POOL_CHUNK_MB )); then
            BUFFER_POOL_MB=$MYSQL_BUFFER_POOL_CHUNK_MB
        fi
        TOTAL_MEM_MB=$(free -m | awk '/^Mem:/ {print $2}')
        echo "  Available memory: ${TOTAL_MEM_MB}MB — suggested buffer pool: ${BUFFER_POOL_MB}MB"
        prompt_if_unset MYSQL_BUFFER_POOL_MB "  InnoDB buffer pool size (MB)" n "$BUFFER_POOL_MB"
    fi

    # Validate pool size is a multiple of chunk size — whether from conf or user input
    REMAINDER=$(( MYSQL_BUFFER_POOL_MB % MYSQL_BUFFER_POOL_CHUNK_MB ))
    if (( REMAINDER != 0 )); then
        CORRECTED=$(( (MYSQL_BUFFER_POOL_MB / MYSQL_BUFFER_POOL_CHUNK_MB) * MYSQL_BUFFER_POOL_CHUNK_MB ))
        echo "  Warning: buffer pool ${MYSQL_BUFFER_POOL_MB}MB is not a multiple of chunk size ${MYSQL_BUFFER_POOL_CHUNK_MB}MB — adjusting to ${CORRECTED}MB"
        MYSQL_BUFFER_POOL_MB=$CORRECTED
    fi

    prompt_if_unset MYSQL_BUFFER_POOL_INSTANCES "  InnoDB buffer pool instances (1-64)" n "1"
    prompt_if_unset MYSQL_MAX_CONNECTIONS       "  Max connections"                    n "100"
    prompt_if_unset MYSQL_LOG_BUFFER_MB         "  InnoDB log buffer size (MB)"        n "64"
    prompt_if_unset MYSQL_BINLOG_CACHE_MB       "  Binlog cache size (MB)"             n "16"
    prompt_if_unset MYSQL_JOIN_BUFFER_KB        "  Join buffer size (KB)"              n "512"
    prompt_if_unset MYSQL_SORT_BUFFER_KB        "  Sort buffer size (KB)"              n "512"
    prompt_if_unset MYSQL_READ_BUFFER_KB        "  Read buffer size (KB)"              n "128"
    prompt_if_unset MYSQL_READ_RND_BUFFER_KB    "  Read rnd buffer size (KB)"          n "1024"

else
    MYSQL_PASS=''
    #MYSQL_PASS_CONFIRM=''
    MYSQL_PASS_ESCAPED=''
fi

prompt_if_unset INSTALL_POSTGRESQL "Would you like to $PROMPT_POSTGRESQL PostgreSQL $PG_VERSION? (y/n)" n "n"
if [[ "$INSTALL_POSTGRESQL" =~ ^[Yy]$ ]]; then
    # Interactive password prompt with 4-character minimum
    while true; do
        prompt_if_unset PG_PASS "  PostgreSQL superuser (postgres) password" secret
        if [ "${#PG_PASS}" -ge 4 ]; then
            break
        fi
        PG_PASS=''
        echo "  Password is too short. Must be at least 4 characters."
    done

    prompt_if_unset PG_MAX_CONNECTIONS         "  Max connections"                        n "100"

    TOTAL_MEM_MB=$(free -m | awk '/^Mem:/ {print $2}')
    TEMP_SHARED_BUFFERS_MB=$(( TOTAL_MEM_MB * 25 / 100 ))
    TEMP_EFFECTIVE_CACHE_MB=$(( TOTAL_MEM_MB * 60 / 100 ))
    TEMP_WORK_MEM_MB=$(( (TOTAL_MEM_MB * 25 / 100) / PG_MAX_CONNECTIONS ))
    # floor of 4MB, cap at 16MB for a general web server
    if (( TEMP_WORK_MEM_MB < 4 ));  then TEMP_WORK_MEM_MB=4;  fi
    if (( TEMP_WORK_MEM_MB > 16 )); then TEMP_WORK_MEM_MB=16; fi
    TEMP_MAX_PARALLEL_WORKERS_P=$(( PROCESSOR_COUNT / 2 ))
    if (( TEMP_MAX_PARALLEL_WORKERS_P < 1 )); then TEMP_MAX_PARALLEL_WORKERS_P=1; fi

    echo "  Available memory: ${TOTAL_MEM_MB}MB, CPU cores: ${PROCESSOR_COUNT}"
    echo "  Suggested: shared_buffers=${TEMP_SHARED_BUFFERS_MB}MB, work_mem=${TEMP_WORK_MEM_MB}MB, effective_cache_size=${TEMP_EFFECTIVE_CACHE_MB}MB"

    prompt_if_unset PG_SHARED_BUFFERS_MB       "  Shared buffers (MB)"                    n "$TEMP_SHARED_BUFFERS_MB"
    prompt_if_unset PG_WORK_MEM_MB             "  Work mem (MB)"                          n "$TEMP_WORK_MEM_MB"
    prompt_if_unset PG_EFFECTIVE_CACHE_MB      "  Effective cache size (MB)"              n "$TEMP_EFFECTIVE_CACHE_MB"
    prompt_if_unset PG_MAX_WORKER_PROCESSES    "  Max worker processes (= cores)"     n "$PROCESSOR_COUNT"
    prompt_if_unset PG_MAX_PARALLEL_WORKERS    "  Max parallel workers (= cores)"     n "$PROCESSOR_COUNT"
    prompt_if_unset PG_MAX_PARALLEL_WORKERS_PG "  Max parallel workers per gather (= cores/2)" n "$TEMP_MAX_PARALLEL_WORKERS_P"
    prompt_if_unset PG_EFFECTIVE_IO_CONCURRENCY "  Effective IO concurrency (SSD=100+, HDD=1)" n "100"
else
    PG_PASS=''
    PG_PASS_ESCAPED=''
fi

prompt_if_unset INSTALL_MOSQUITTO "Would you like to $PROMPT_MOSQUITTO Mosquitto? (y/n)" n "n"

prompt_if_unset INSTALL_POSTFIX "Would you like to $PROMPT_POSTFIX Postfix (relay-only SMTP)? (y/n)" n "n"
if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ ]]; then
    prompt_if_unset POSTFIX_RELAY_HOST      "  SMTP relay host"                          n
    prompt_if_unset POSTFIX_RELAY_PORT      "  SMTP relay port"                          n "587"
    prompt_if_unset POSTFIX_RELAY_USERNAME  "  SMTP relay username"                      n
    while true; do
        prompt_if_unset POSTFIX_RELAY_PASSWORD "  SMTP relay password"                   secret
        if [ "${#POSTFIX_RELAY_PASSWORD}" -ge 4 ]; then
            break
        fi
        POSTFIX_RELAY_PASSWORD=''
        echo "  Password is too short. Must be at least 4 characters."
    done
    TEMP_POSTFIX_DOMAIN="${POSTFIX_RELAY_USERNAME#*@}"
    prompt_if_unset POSTFIX_DOMAIN          "  Mail domain (used in From address)"       n $TEMP_POSTFIX_DOMAIN
    prompt_if_unset POSTFIX_FROM_ADDRESS    "  From address (e.g. root@domain.com)"      n "root@${POSTFIX_DOMAIN}"
    prompt_if_unset POSTFIX_ROOT_ALIAS      "  Forward root mail to"                     n
else
    POSTFIX_RELAY_HOST=''
    POSTFIX_RELAY_PORT=''
    POSTFIX_RELAY_USERNAME=''
    POSTFIX_RELAY_PASSWORD=''
    POSTFIX_DOMAIN=''
    POSTFIX_FROM_ADDRESS=''
    POSTFIX_ROOT_ALIAS=''
fi

prompt_if_unset INSTALL_MONIT "Would you like to $PROMPT_MONIT Monit? (y/n)" n "n"
if [[ "$INSTALL_MONIT" =~ ^[Yy]$ ]]; then
    # allow conf file to override, fall back to hostname, never prompt
	  MONIT_HOST_NAME="${MONIT_HOST_NAME:-$LOCAL_HOSTNAME}"

    if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ ]]; then
        prompt_if_unset MONIT_USE_POSTFIX "  Send Monit alerts via Postfix? (y/n)" n "y"
    else
        MONIT_USE_POSTFIX="n"
    fi

    if [[ ! "$MONIT_USE_POSTFIX" =~ ^[Yy]$ ]]; then
        prompt_if_unset MONIT_MAILSERVER_HOST     "  Mail server host"       n
        prompt_if_unset MONIT_MAILSERVER_PORT     "  Mail server port"       n    "587"
        prompt_if_unset MONIT_MAILSERVER_USERNAME "  Mail server username"   n
        while true; do
            prompt_if_unset MONIT_MAILSERVER_PASSWORD "  Mail server password"   secret
            if [ "${#MONIT_MAILSERVER_PASSWORD}" -ge 4 ]; then
                break
            fi
            MONIT_MAILSERVER_PASSWORD=''
            echo "  Password is too short. Must be at least 4 characters."
        done
        prompt_if_unset MONIT_ALERT_SENDER        "  Alert sender address"   n    "$MONIT_MAILSERVER_USERNAME"
    else
        MONIT_MAILSERVER_HOST="localhost"
        MONIT_MAILSERVER_PORT="25"
        MONIT_MAILSERVER_USERNAME=""
        MONIT_MAILSERVER_PASSWORD=""
        prompt_if_unset MONIT_ALERT_SENDER        "  Alert sender address"   n    "monit@${POSTFIX_DOMAIN}"
    fi
	prompt_if_unset MONIT_ADMIN_USERNAME      "  Monit admin username"   n    "admin"
	while true; do
	    prompt_if_unset MONIT_ADMIN_PASSWORD "  Monit admin password"   secret
	    if [ "${#MONIT_ADMIN_PASSWORD}" -ge 4 ]; then
	        break
	    fi
	    MONIT_ADMIN_PASSWORD=''
	    echo "  Password is too short. Must be at least 4 characters."
	done
	prompt_if_unset MONIT_ALERT_RECIPIENT     "  Alert recipient address" n
fi


prompt_if_unset INSTALL_WEBMIN "Would you like to $PROMPT_WEBMIN Webmin? (y/n)" n "n"

prompt_if_unset INSTALL_GRAFANA "Would you like to $PROMPT_GRAFANA Grafana? (y/n)" n "n"
if [[ "$INSTALL_GRAFANA" =~ ^[Yy]$ ]]; then
    if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ ]]; then
        prompt_if_unset GRAFANA_USE_POSTFIX "  Send Grafana alerts via Postfix? (y/n)" n "y"
    else
        GRAFANA_USE_POSTFIX="n"
    fi

    if [[ "$GRAFANA_USE_POSTFIX" =~ ^[Yy]$ ]]; then
        GRAFANA_SMTP_ENABLED="true"
        GRAFANA_SMTP_HOST="localhost"
        GRAFANA_SMTP_PORT="25"
        GRAFANA_SMTP_USER=""
        GRAFANA_SMTP_PASSWORD=""
        prompt_if_unset GRAFANA_SMTP_FROM_ADDRESS "  From address"                        n "grafana@${POSTFIX_DOMAIN}"
        prompt_if_unset GRAFANA_SMTP_FROM_NAME    "  From name"                           n "Grafana"
        GRAFANA_SMTP_EHLO_IDENTITY=""
        GRAFANA_SMTP_STARTTLS_POLICY="NoConfig"
    else
        prompt_if_unset GRAFANA_SMTP_ENABLED        "  Enable SMTP? (true/false)"           n "true"
        if [[ "$GRAFANA_SMTP_ENABLED" == "true" ]]; then
            prompt_if_unset GRAFANA_SMTP_HOST           "  SMTP host"                           n
            prompt_if_unset GRAFANA_SMTP_PORT           "  SMTP port"                           n "587"
            prompt_if_unset GRAFANA_SMTP_USER           "  SMTP username"                       n
            while true; do
                prompt_if_unset GRAFANA_SMTP_PASSWORD   "  SMTP password"                       secret
                if [ "${#GRAFANA_SMTP_PASSWORD}" -ge 4 ]; then
                    break
                fi
                GRAFANA_SMTP_PASSWORD=''
                echo "  Password is too short. Must be at least 4 characters."
            done
            prompt_if_unset GRAFANA_SMTP_FROM_ADDRESS   "  From address"                        n "$GRAFANA_SMTP_USER"
            prompt_if_unset GRAFANA_SMTP_FROM_NAME      "  From name"                           n "Grafana"
            prompt_if_unset GRAFANA_SMTP_EHLO_IDENTITY  "  EHLO identity (usually your domain)"  n "$GRAFANA_SMTP_HOST"
            prompt_if_unset GRAFANA_SMTP_STARTTLS_POLICY "  StartTLS policy (NoConfig/MandatoryStartTLS/OpportunisticStartTLS)" n "MandatoryStartTLS"
        fi
    fi
fi

prompt_if_unset INSTALL_FORGEJO "Would you like to $PROMPT_FORGEJO Forgejo? (y/n)" n "n"
if [[ "$INSTALL_FORGEJO" =~ ^[Yy]$ ]]; then
    if [[ "$INSTALL_GRAFANA" =~ ^[Yy]$ ]]; then
        # If already set to 3000 (Grafana's port), clear it so the prompt fires
        FORGEJO_PORT="${FORGEJO_PORT:-}"
        if [[ "$FORGEJO_PORT" == "3000" ]]; then
            echo "  Warning: FORGEJO_PORT=3000 conflicts with Grafana. Resetting."
            FORGEJO_PORT=""
        fi
        prompt_if_unset FORGEJO_PORT "  Port 3000 is in use by Grafana. Enter Forgejo port" n "$FORGEJO_FALLBACK_PORT"
    else
        FORGEJO_PORT="${FORGEJO_PORT:-3000}"
    fi
    prompt_if_unset FORGEJO_DOMAIN "  Enter Forgejo domain or ip" n "$LOCAL_IP"

    if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ ]]; then
        prompt_if_unset FORGEJO_USE_POSTFIX "  Send Forgejo mail via Postfix? (y/n)" n "y"
    else
        FORGEJO_USE_POSTFIX="n"
    fi

    if [[ "$FORGEJO_USE_POSTFIX" =~ ^[Yy]$ ]]; then
        FORGEJO_MAILER_ENABLED="true"
        FORGEJO_SMTP_ADDR=""
        FORGEJO_SMTP_PORT=""
        FORGEJO_SMTP_USER=""
        FORGEJO_SMTP_PASSWORD=""
        prompt_if_unset FORGEJO_SMTP_FROM "  From address"  n "forgejo@${POSTFIX_DOMAIN}"
    else
        prompt_if_unset FORGEJO_MAILER_ENABLED  "  Enable mailer? (true/false)"  n "true"
        if [[ "$FORGEJO_MAILER_ENABLED" == "true" ]]; then
            prompt_if_unset FORGEJO_SMTP_ADDR   "  SMTP host"                   n
            prompt_if_unset FORGEJO_SMTP_PORT   "  SMTP port"                   n "587"
            prompt_if_unset FORGEJO_SMTP_FROM   "  From address"                n
            prompt_if_unset FORGEJO_SMTP_USER   "  SMTP username"               n
            while true; do
                prompt_if_unset FORGEJO_SMTP_PASSWORD "  SMTP password"         secret
                if [ "${#FORGEJO_SMTP_PASSWORD}" -ge 4 ]; then
                    break
                fi
                FORGEJO_SMTP_PASSWORD=''
                echo "  Password is too short. Must be at least 4 characters."
            done
        fi
    fi
fi
prompt_if_unset DISABLE_TX_OFFLOAD "Would you like to disable TCP transmit offloading? (y/n)" n "n"
prompt_if_unset INSTALL_FAIL2BAN "Would you like to $PROMPT_FAIL2BAN Fail2Ban? (y/n)" n "n"
prompt_if_unset INSTALL_AUDITD "Would you like to $PROMPT_AUDITD auditd? (y/n)" n "n"
prompt_if_unset INSTALL_IPBLOCK "Would you like to $PROMPT_IPBLOCK IP blocklist? (y/n)" n "n"
prompt_if_unset INSTALL_SURICATA "Would you like to $PROMPT_SURICATA Suricata IDS? (y/n)" n "n"
prompt_if_unset INSTALL_WAZUH "Would you like to $PROMPT_WAZUH Wazuh Agent? (y/n)" n "n"
if [[ "$INSTALL_WAZUH" =~ ^[Yy]$ ]]; then
    # Interactive Manager host prompt
    while true; do
        #read -p "  Enter IP or Hostname of Wazuh Manager : " WAZUH_MANAGER
        prompt_if_unset WAZUH_MANAGER "  Enter IP or Hostname of Wazuh Manager" n
        echo
        if [[ ${#WAZUH_MANAGER} -ge 4 ]]; then
            break
        fi
    done
else
    WAZUH_MANAGER=''
fi

echo ""
prompt_if_unset CONFIGURE_APPARMOR "Would you like to configure AppArmor? (y/n)" n "y"
if [[ "$CONFIGURE_APPARMOR" =~ ^[Yy]$ ]]; then
    echo "  AppArmor status: installed=$APPARMOR_INSTALLED, enabled=$APPARMOR_ENABLED, mode=$APPARMOR_CURRENT_MODE"
    prompt_if_unset APPARMOR_ENABLE "  Enable AppArmor? (y/n)" n "y"
    prompt_if_unset APPARMOR_ENFORCE "  Set profiles to enforce mode? (y/n)" n "$( [[ "$APPARMOR_CURRENT_MODE" == "enforce" ]] && echo y || echo n )"
fi
echo "Configuration complete."

## Print Configuration
## --------------------------------------------
echo ""
echo ""
echo "-- Configuration settings --"
echo "Add sudo user?           : $USER_CREATE_SUDO_USER"
if [[ "$USER_CREATE_SUDO_USER" =~ ^[Yy]$ ]]; then
  echo "           new username : $USER_SUDO_USER_USERNAME"
else
  echo "      existing username : $USER_SUDO_USER_USERNAME"
fi
echo "Configure LVM disks?     : $CONFIGURE_LVM"
if [[ "$CONFIGURE_LVM" =~ ^[Yy]$ ]]; then
  echo "         Resize LVM?    : ${LVM_DO_RESIZE:-n}"
  if [[ "$LVM_DO_RESIZE" =~ ^[Yy]$ ]]; then
    echo "         LVM target GB  : ${LVM_TARGET_GB:-all}"
  fi
fi
echo "Configure swap space?    : $CONFIGURE_SWAP"
if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ && "$ACTIVE_SWAP" == "No" ]]; then
  echo "         Swap size (GB) : ${SWAP_SIZE_GB:-2}"
fi
echo "Tune system?             : $TUNE_SYSTEM"
if [[ "$TUNE_SYSTEM" =~ ^[Yy]$ ]]; then
  echo "  apt update hour (UTC) : $APT_DAILY_HOUR and $APT_DAILY_HOUR_2 (twice daily)"
  echo "  apt upgrade hour (UTC): $APT_UPGRADE_HOUR"
fi
echo "Uninstall extra packages?  : $UNINSTALL_PACKAGES"
echo "Update installed packages? : $UPDATE_PACKAGES"
echo "Install admin packages?    : $INSTALL_PACKAGES"
echo "Install ufw?               : $INSTALL_UFW"
echo "Install ssh?               : $INSTALL_SSH"
echo "Install fonts?             : $INSTALL_FONTS"
if [[ "$INSTALL_FONTS" =~ ^[Yy]$ ]]; then
  echo "  Install MS core fonts    : $INSTALL_MS_FONTS"
fi
echo "Install weasyprint?        : $INSTALL_WEASYPRINT"
echo "Install imagemagick?       : $INSTALL_IMAGEMAGICK"
echo "Install Python 3.14?       : $INSTALL_CPYTHON314"
echo "Install Pypy 3.11?         : $INSTALL_PYPY311"
echo "Install nginx?             : $INSTALL_NGINX"
if [[ "$INSTALL_NGINX" =~ ^[Yy]$ ]]; then
  echo "  nginx worker processes   : $NGINX_WORKER_PROCESSES"
fi
echo "Install valkey?            : $INSTALL_VALKEY"
echo "Install MySQL?             : $INSTALL_MYSQL"
if [[ "$INSTALL_MYSQL" =~ ^[Yy]$ ]]; then
  echo "  Buffer pool chunk MB     : $MYSQL_BUFFER_POOL_CHUNK_MB"
  echo "  Buffer pool MB           : $MYSQL_BUFFER_POOL_MB"
  echo "  Buffer pool instances    : $MYSQL_BUFFER_POOL_INSTANCES"
  echo "  Max connections          : $MYSQL_MAX_CONNECTIONS"
  echo "  Log buffer MB            : $MYSQL_LOG_BUFFER_MB"
  echo "  Binlog cache MB          : $MYSQL_BINLOG_CACHE_MB"
  echo "  Join buffer KB           : $MYSQL_JOIN_BUFFER_KB"
  echo "  Sort buffer KB           : $MYSQL_SORT_BUFFER_KB"
  echo "  Read buffer KB           : $MYSQL_READ_BUFFER_KB"
  echo "  Read rnd buffer KB       : $MYSQL_READ_RND_BUFFER_KB"
fi
echo "Install PostgreSQL?        : $INSTALL_POSTGRESQL"
if [[ "$INSTALL_POSTGRESQL" =~ ^[Yy]$ ]]; then
  echo "  Max connections          : $PG_MAX_CONNECTIONS"
  echo "  Shared buffers MB        : $PG_SHARED_BUFFERS_MB"
  echo "  Work mem MB              : $PG_WORK_MEM_MB"
  echo "  Effective cache MB       : $PG_EFFECTIVE_CACHE_MB"
  echo "  Max worker processes     : $PG_MAX_WORKER_PROCESSES"
  echo "  Max parallel workers     : $PG_MAX_PARALLEL_WORKERS"
  echo "  Max parallel w/gather    : $PG_MAX_PARALLEL_WORKERS_PG"
  echo "  Effective IO concurr.    : $PG_EFFECTIVE_IO_CONCURRENCY"
  echo "  Superuser password       : [set]"
fi
echo "Install Mosquitto?         : $INSTALL_MOSQUITTO"
echo "Install Postfix?           : $INSTALL_POSTFIX"
if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ ]]; then
  echo "  Relay host               : $POSTFIX_RELAY_HOST:$POSTFIX_RELAY_PORT"
  echo "  Relay username           : $POSTFIX_RELAY_USERNAME"
  echo "  Relay password           : [set]"
  echo "  Mail domain              : $POSTFIX_DOMAIN"
  echo "  From address             : $POSTFIX_FROM_ADDRESS"
  echo "  Root alias               : $POSTFIX_ROOT_ALIAS"
fi
echo "Install Monit?             : $INSTALL_MONIT"
if [[ "$INSTALL_MONIT" =~ ^[Yy]$ ]]; then
  echo "  Monit host name          : $MONIT_HOST_NAME"
  if [[ "$MONIT_USE_POSTFIX" =~ ^[Yy]$ ]]; then
    echo "  Mail via               : Postfix (localhost:25)"
  else
    echo "  Mail server host       : $MONIT_MAILSERVER_HOST"
    echo "  Mail server port       : $MONIT_MAILSERVER_PORT"
    echo "  Mail server username   : $MONIT_MAILSERVER_USERNAME"
    echo "  Mail server password   : [set]"
  fi
  echo "  Monit admin username     : $MONIT_ADMIN_USERNAME"
  echo "  Monit admin password     : [set]"
  echo "  Alert sender             : $MONIT_ALERT_SENDER"
  echo "  Alert recipient          : $MONIT_ALERT_RECIPIENT"
fi
echo "Install Webmin?            : $INSTALL_WEBMIN"
echo "Install Grafana?           : $INSTALL_GRAFANA"
if [[ "$INSTALL_GRAFANA" =~ ^[Yy]$ ]]; then
  echo "  Random secret            : [set]"

  if [[ "$GRAFANA_USE_POSTFIX" =~ ^[Yy]$ ]]; then
    echo "  Mail via                 : Postfix (localhost:25)"
    echo "  From address             : $GRAFANA_SMTP_FROM_ADDRESS"
    echo "  From name                : $GRAFANA_SMTP_FROM_NAME"
  else
    echo "  SMTP enabled           : $GRAFANA_SMTP_ENABLED"
    if [[ "$GRAFANA_SMTP_ENABLED" == "true" ]]; then
      echo "  SMTP host              : $GRAFANA_SMTP_HOST"
      echo "  SMTP port              : $GRAFANA_SMTP_PORT"
      echo "  SMTP user              : $GRAFANA_SMTP_USER"
      echo "  SMTP password          : [set]"
      echo "  From address           : $GRAFANA_SMTP_FROM_ADDRESS"
      echo "  From name              : $GRAFANA_SMTP_FROM_NAME"
      echo "  EHLO identity          : $GRAFANA_SMTP_EHLO_IDENTITY"
      echo "  StartTLS policy        : $GRAFANA_SMTP_STARTTLS_POLICY"
    fi
  fi
fi
echo "Install Forgejo?         : $INSTALL_FORGEJO"
if [[ "$INSTALL_FORGEJO" =~ ^[Yy]$ ]]; then
  echo "  Forgejo domain/ip          : $FORGEJO_DOMAIN"
  echo "  Forgejo port               : $FORGEJO_PORT"
  if [[ "$FORGEJO_USE_POSTFIX" =~ ^[Yy]$ ]]; then
    echo "  Mail via                  : Postfix (localhost:25)"
    echo "  From address              : $FORGEJO_SMTP_FROM"
  else
    echo "  Mailer enabled          : $FORGEJO_MAILER_ENABLED"
    if [[ "$FORGEJO_MAILER_ENABLED" == "true" ]]; then
      echo "  SMTP host                 : $FORGEJO_SMTP_ADDR"
      echo "  SMTP port                 : $FORGEJO_SMTP_PORT"
      echo "  From address              : $FORGEJO_SMTP_FROM"
      echo "  SMTP user                 : $FORGEJO_SMTP_USER"
      echo "  SMTP password             : [set]"
    fi
  fi
fi
echo "Disable TX offloading?       : $DISABLE_TX_OFFLOAD"
if [[ "$DISABLE_TX_OFFLOAD" =~ ^[Yy]$ ]]; then
  echo "  Interface                  : $PRIMARY_INTERFACE"
fi
echo "Install Fail2Ban?            : $INSTALL_FAIL2BAN"
echo "Install auditd?              : $INSTALL_AUDITD"
echo "Install IP blocklist?        : $INSTALL_IPBLOCK"
echo "Install Suricata IDS?        : $INSTALL_SURICATA"
echo "Install Wazuh Agent?         : $INSTALL_WAZUH"
if [[ "$INSTALL_WAZUH" =~ ^[Yy]$ ]]; then
  echo "          Wazuh Manager      : $WAZUH_MANAGER"
fi
echo "Configure AppArmor?          : $CONFIGURE_APPARMOR"
if [[ "$CONFIGURE_APPARMOR" =~ ^[Yy]$ ]]; then
  echo "  Enable AppArmor            : $APPARMOR_ENABLE"
  echo "  Enforce mode               : $APPARMOR_ENFORCE"
fi

echo ""
save_config

echo ""
read -rp "Configuration printed above. Proceed with installation? (y/n) " CONFIRM_APPLY
if [[ ! "$CONFIRM_APPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted by user."
    exit 0
fi


echo ""
echo "--- 3. Backup current configuration ---"
BACKUP_SCRIPT="$(dirname "$(readlink -f "$0")")/ubuntu_backup_config.sh"
if [[ -f "$BACKUP_SCRIPT" ]]; then
    bash "$BACKUP_SCRIPT" "pre-apply"
    echo "Pre-apply configuration backup complete."
else
    echo "Warning: ubuntu_backup_config.sh not found alongside this script, skipping backup."
fi


## Apply settings
## --------------------------------------------

echo ""
echo "--- 4. Create/update user ---"
if [[ "$USER_CREATE_SUDO_USER" =~ ^[Yy]$ ]]; then
    if ! id "$USER_SUDO_USER_USERNAME" &>/dev/null; then
        echo "Creating user $USER_SUDO_USER_USERNAME."
        adduser --gecos "" --disabled-password "$USER_SUDO_USER_USERNAME"
        echo "Created user $USER_SUDO_USER_USERNAME"
        echo ""
        echo "Setting system password for user: $USER_SUDO_USER_USERNAME"
        passwd $USER_SUDO_USER_USERNAME
        usermod -aG sudo $USER_SUDO_USER_USERNAME
        usermod -a -G adm $USER_SUDO_USER_USERNAME
        chmod 750 /home/$USER_SUDO_USER_USERNAME
    else
        echo "User $USER_SUDO_USER_USERNAME exists."
    fi
    echo "Adding user $USER_SUDO_USER_USERNAME to groups sudo and adm"
    usermod -a -G sudo $USER_SUDO_USER_USERNAME
    usermod -a -G adm $USER_SUDO_USER_USERNAME
    echo "Updating home folder permissions."
    chmod 750 /home/$USER_SUDO_USER_USERNAME
else
    echo "Skipping new sudo user."
    echo "Adding user $USER_SUDO_USER_USERNAME to groups sudo and adm"
    usermod -a -G sudo $USER_SUDO_USER_USERNAME
    usermod -a -G adm $USER_SUDO_USER_USERNAME
    echo "Updating home folder permissions."
    chmod 750 /home/$USER_SUDO_USER_USERNAME
fi


echo ""
echo "--- 5. Configure LVM disks ---"
if [[ "$CONFIGURE_LVM" =~ ^[Yy]$ ]]; then
    # 1. Check if the logical volume exists
    # 2. Check if the Volume Group has more than 0 free space
    VG_NAME="ubuntu-vg"
    LV_PATH="/dev/ubuntu-vg/ubuntu-lv"

    if lvs "$LV_PATH" &>/dev/null; then
        LVM_FREE_SPACE=$(vgs "$VG_NAME" --noheadings -o vg_free_count | xargs)
        # Convert extents to approximate GB (assuming 4MB extents)
        LVM_FREE_GB=$(vgs "$VG_NAME" --noheadings --units g -o vg_free | xargs | tr -d 'g')

        if [ "$LVM_FREE_SPACE" -gt 0 ]; then
            #echo "LVM detected with $LVM_FREE_SPACE free extents."
            echo "LVM detected. Free space in Volume Group: ${LVM_FREE_GB}GB"

            #read -p "Resize root LVM? (y/n)" LVM_DO_RESIZE
            prompt_if_unset LVM_DO_RESIZE "Resize root LVM? (y/n)" n "n"
            if [[ "$LVM_DO_RESIZE" =~ ^[Yy]$ ]]; then
                #read -p "Enter target size in GB (or type 'all'): " LVM_TARGET_GB
                prompt_if_unset LVM_TARGET_GB "Enter target size in GB (or type 'all')" n "all"

                if [ "$LVM_TARGET_GB" == "all" ]; then
                    lvextend -l +100%FREE "$LV_PATH"
                else
                    lvextend -L "${LVM_TARGET_GB}G" "$LV_PATH"
                fi
                resize2fs "$LV_PATH"
            fi

        else
            echo "LVM detected, but no free space remains in Volume Group. Skipping."
        fi
    else
        echo "Logical Volume $LV_PATH not found (System may not use LVM). Skipping."
    fi
else
    echo "Skipping LVM configuration."
fi


echo ""
echo "--- 6. Configure Swap Space ---"
if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ ]]; then
    # 1. Check if swap is currently active (via /proc/swaps)
    # We ignore the header line; if the output is empty, no swap is active.
    CURRENT_SWAP_ACTIVE=$(tail -n +2 /proc/swaps)

    if [ -z "$CURRENT_SWAP_ACTIVE" ]; then
        echo "No active swap detected."
        #read -p "Would you like to create a swap file? (y/n)" CONFIGURE_SWAP
        prompt_if_unset CONFIGURE_SWAP "Would you like to create a swap file? (y/n)" n "all"

        if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ ]]; then
            # Ask for size with a sensible default
            #read -p "Enter swap size in GB [Default: 2]: " SWAP_SIZE_GB
            #SWAP_SIZE_GB=${SWAP_SIZE_GB:-2} # Fallback to 2 if empty
            prompt_if_unset SWAP_SIZE_GB "Enter swap size in GB" n "2"


            # Define the path (using /swapfile as per your original script)
            SWAP_PATH="/swapfile"

            if [ ! -f "$SWAP_PATH" ]; then
                echo "Creating ${SWAP_SIZE_GB}GB swap file at $SWAP_PATH..."
                # fallocate is faster, dd is the fallback
                fallocate -l "${SWAP_SIZE_GB}G" "$SWAP_PATH" || dd if=/dev/zero of="$SWAP_PATH" bs=1M count=$((SWAP_SIZE_GB * 1024))

                chmod 600 "$SWAP_PATH"
                mkswap "$SWAP_PATH"
                swapon "$SWAP_PATH"

                # Append to fstab if not already there
                if ! grep -q "$SWAP_PATH" /etc/fstab; then
                    echo "$SWAP_PATH none swap sw 0 0" >> /etc/fstab
                fi
                echo "Swap file created and activated."
            else
                echo "A file exists at $SWAP_PATH but is not active. Please check manually."
            fi
        fi
    else
        echo "Active swap detected. Skipping creation."
        swapon --show
    fi
else
    echo "Skipping swap configuration."
fi


echo ""
echo "--- 7. Uninstall unneeded packages ---"
if [[ "$UNINSTALL_PACKAGES" =~ ^[Yy]$ ]]; then
    apt-get purge -y --auto-remove modemmanager udisks2 apport bluetooth bluez snapd snapd-core || true

    # Cleanup leftover config packages
    # sudo apt-get autoremove -y ; sudo apt-get -y purge $(dpkg --list | grep ^rc | awk '{ print $2; }')
    mapfile -t RC_PACKAGES < <(dpkg --list | awk '/^rc/ {print $2}')
    if [ ${#RC_PACKAGES[@]} -gt 0 ]; then
        echo "Purging leftover configuration packages: ${RC_PACKAGES[*]}"
        apt-get purge -y "${RC_PACKAGES[@]}" || true
    else
        echo "No leftover config packages found."
    fi
    apt-get autoremove -y || true
else
    echo "Skipping uninstall."
fi


echo ""
echo "--- 8. Update system packages ---"
if [[ "$UPDATE_PACKAGES" =~ ^[Yy]$ ]]; then
    wait_for_apt
    apt-get update
    apt-get -y full-upgrade
else
    echo "Skipping update."
fi


echo ""
echo "--- 9. Install recommended tools ---"
if [[ "$INSTALL_PACKAGES" =~ ^[Yy]$ ]]; then
    wait_for_apt
    apt-get install $APT_FLAGS apt-show-versions apt-utils btop ca-certificates curl \
    debsums dnsutils git git-lfs gnupg gnupg2 gpg iftop iotop iputils-ping jq lsb-release \
    lsof lynis mc micro nano ncdu ne needrestart net-tools nmap p7zip-full rsync \
    sed speedtest-cli sysstat tmux unattended-upgrades unzip vim vim-gui-common wget zip

    if [[ "$(systemd-detect-virt)" == "none" ]]; then
        echo "Bare metal detected. Installing smartmontools"
        apt-get install $APT_FLAGS smartmontools
    else
        echo "Running in $(systemd-detect-virt). Skipping smartmontools installation."
    fi
else
    echo "Skipping tools installation."
fi


echo ""
echo "--- 10. Install and configure ufw firewall ---"
if [[ "$INSTALL_UFW" =~ ^[Yy]$ ]]; then
    wait_for_apt
    apt-get install $APT_FLAGS ufw rsyslog
    ufw default allow outgoing
    ufw default deny incoming
    ufw allow 22/tcp
    if [[ "$INSTALL_NGINX" =~ ^[Yy]$ ]]; then
        ufw allow 80/tcp
        ufw allow 443/tcp
    fi
    ufw --force enable
    sed -i 's/#& stop/\& stop/' /etc/rsyslog.d/20-ufw.conf
    systemctl restart rsyslog || true
else
    echo "Skipping ufw installation."
fi

echo ""
echo "--- 11. Install and configure OpenSSH ---"
if [[ "$INSTALL_SSH" =~ ^[Yy]$ ]]; then
    wait_for_apt
    apt-get install $APT_FLAGS openssh-server

    # SSH Key Logic: Prompt for ssh key if none exists
    mkdir -p /home/$USER_SUDO_USER_USERNAME/.ssh
    chown $USER_SUDO_USER_USERNAME:$USER_SUDO_USER_USERNAME /home/$USER_SUDO_USER_USERNAME/.ssh
    chmod 700 /home/$USER_SUDO_USER_USERNAME/.ssh
    AUTH_KEYS="/home/$USER_SUDO_USER_USERNAME/.ssh/authorized_keys"
    if [ ! -f "$AUTH_KEYS" ] || [ ! -s "$AUTH_KEYS" ]; then
        echo "SSH KEY SETUP"
        echo "No existing keys found for $USER_SUDO_USER_USERNAME."
        echo "Please paste your SSH PUBLIC KEY (starts with ssh-rsa, ssh-ed25519, etc.):"
        read -r SSH_PUBLIC_KEY
        if [ -n "$SSH_PUBLIC_KEY" ]; then
            mkdir -p /home/$USER_SUDO_USER_USERNAME/.ssh
            echo "$SSH_PUBLIC_KEY" > "$AUTH_KEYS"
            chmod 700 /home/$USER_SUDO_USER_USERNAME/.ssh
            chmod 600 "$AUTH_KEYS"
            chown -R $USER_SUDO_USER_USERNAME:$USER_SUDO_USER_USERNAME /home/$USER_SUDO_USER_USERNAME/.ssh
            echo "SSH key installed for $USER_SUDO_USER_USERNAME."
        else
            #echo "WARNING: No SSH key provided! You will be locked out after SSH hardening."
            echo "ERROR: No SSH key installed. Aborting to prevent lockout."
            exit 1
        fi
    else
        echo "SSH keys already present in $AUTH_KEYS. Skipping prompt."
    fi

    echo "Hardening ssh..."
    # Override file ensures custom settings take precedence in Ubuntu 26.04.
    # Using <<EOF, not <<'EOF', so that $USER_SUDO_USER_USERNAME is replaced.
    cat <<EOF > /etc/ssh/sshd_config.d/01-$USER_SUDO_USER_USERNAME-hardened.conf
UsePAM yes
PermitRootLogin no
ChallengeResponseAuthentication no
PasswordAuthentication no
PermitEmptyPasswords no
MaxStartups 3:50:10
LoginGraceTime 10
MaxAuthTries 3
PubkeyAuthentication yes
AllowUsers $USER_SUDO_USER_USERNAME
ClientAliveCountMax 2
MaxSessions 2
AllowTcpForwarding yes
TCPKeepAlive no
X11Forwarding no
IgnoreRhosts yes
AuthenticationMethods publickey
PrintMotd yes
EOF
    # sshd is an alias to ssh
    systemctl restart ssh || true
else
    echo "Skipping OpenSSH installation."
fi


if [[ "$TUNE_SYSTEM" =~ ^[Yy]$ ]]; then


    echo ""
    echo "--- 13. Localization  ---"
    echo "Set timezone to UTC"
    timedatectl set-timezone UTC


    echo ""
    echo "--- 14. Override sudo settings ---"
    echo "Defaults timestamp_timeout=60" > /etc/sudoers.d/$USER_SUDO_USER_USERNAME-timeout
    echo "$USER_SUDO_USER_USERNAME ALL=(ALL) NOPASSWD:/usr/bin/apt-get update, /usr/bin/apt-get upgrade, /usr/bin/systemctl, /usr/sbin/reboot, /home/$USER_SUDO_USER_USERNAME/ubuntu_health_check.sh" > /etc/sudoers.d/$USER_SUDO_USER_USERNAME-commands
    # Protect sudoers files
    chmod 440 /etc/sudoers.d/*
    # verify sudoers syntax is valid
    if visudo -c; then
        echo "Sudoers file is valid."
    else
        echo "Error: Sudoers file has errors."
        exit 1
    fi

    echo ""
    echo "--- 15. Override update timer settings ---"
    mkdir -p /etc/systemd/system/apt-daily.timer.d/
    echo -e "[Timer]\nOnCalendar=*-*-* ${APT_DAILY_HOUR},${APT_DAILY_HOUR_2}:00" > /etc/systemd/system/apt-daily.timer.d/override.conf
    mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d/
    echo -e "[Timer]\nOnCalendar=*-*-* ${APT_UPGRADE_HOUR}:00" > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf
    systemctl daemon-reload

    echo ""
    echo "--- 16. Configure system file limits ---"
    rm -f /etc/security/limits.d/xlvisuals.conf
    cat <<'EOF' > /etc/security/limits.d/xlvisuals.conf
# Recommended limits
# These limites apply to PAM-authenticated sessions. Services started by systemd (nginx, MySQL, PostgreSQL, ...)
# use their own LimitNOFILE= directive in the unit file (or a drop-in override).
* soft    nofile   65536
* hard    nofile   1048576
* soft    nproc    65536
* hard    nproc    1048576
root soft nofile   65536
root hard nofile   1048576
root soft nproc    65536
root hard nproc    1048576
EOF

    echo ""
    echo "--- 17. Kernel tuning and hardening ---"
    rm -f /etc/sysctl.d/99-xlvisuals.conf
    cat <<'EOF' > /etc/sysctl.d/99-xlvisuals.conf
# XLVISUALS recommended kernel tuning

# Swap
vm.swappiness=10

# File system
fs.file-max=2097152

# set the restriction level for exposing kernel memory addresses
kernel.kptr_restrict=2

# set the restriction level for exposing kernel message buffer
kernel.dmesg_restrict=1

# Randomizing memory addresses used by processes.
# Adds overhead for MySQL (optional, uncomment to use)
# kernel.randomize_va_space=2

# Ignore ICMP redirects (prevents MITM attacks)
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Ignore bogus ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Prevent IP Spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Do not accept source routed packets
net.ipv4.conf.all.accept_source_route = 0

# protect against SYN flood attacks (optional, uncomment to use)
# net.ipv4.tcp_syncookies=1

# Disable IPv6 if not needed (optional, uncomment to use)
# net.ipv6.conf.all.disable_ipv6 = 1
EOF

    echo "Applying sysctl changes"
    #sysctl -p  # requires /etc/sysctl.conf
    sysctl --system

    echo ""
    echo "--- 18. Secure Shared Memory ---"
    # allow MySQL to write to the memory space, but prevents an attacker from running executables or gain root
    if ! grep -q "none /run/shm tmpfs" /etc/fstab; then
        echo "none /run/shm tmpfs defaults,nosuid,nodev,noexec 0 0" >> /etc/fstab
        echo "Modified /etc/fstab"
    fi
    # Re-mount immediately to apply changes without reboot
    mount -o remount,nosuid,nodev,noexec /run/shm 2>/dev/null || true
    echo "Remounted /run/shm"


    echo ""
    echo "--- 19. Configure needrestart ---"
    # Set needrestart to automatic mode so kernel upgrades and service restarts
    # never prompt during unattended runs
    if [[ -f /etc/needrestart/needrestart.conf ]]; then
        sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf \
            && echo "  needrestart set to automatic mode" \
            || echo "  Warning: could not update needrestart.conf"
    fi

    echo ""
    echo "--- 20. Configure timeouts ---"
    # Set apt timeout so apt doesn't hang waiting on a temporarily unavailable mirror
    echo -e "Acquire::http::Timeout \"5\";\nAcquire::https::Timeout \"5\";\nAcquire::Retries \"0\";" \
        > /etc/apt/apt.conf.d/99timeout
    echo "  apt timeout set to 5s with no retries"


    echo ""
    echo "--- 21. Ubuntu Pro ---"
    if pro status --format json 2>/dev/null | grep -q '"attached": false'; then
        # Removing Ubuntu Pro can sometimes cause issues with apt on Ubuntu since it's fairly integrated.
        # Safer to just disabling the services
        echo "Ubuntu Pro not attached — disabling Pro services"
        pro config set apt_news=false 2>/dev/null || true
        systemctl stop ubuntu-advantage ubuntu-pro-esm-cache.service ubuntu-pro-apt-news.service 2>/dev/null || true
        systemctl mask ubuntu-pro-esm-cache.service ubuntu-pro-apt-news.service 2>/dev/null || true
    else
        echo "Ubuntu Pro is attached — no changes"
    fi

else
    echo ""
    echo "--- 13.-21. System Tuning ---"
    echo "Skipping system tuning steps."
fi


echo ""
echo "--- 22. Install fonts ---"
if [[ "$INSTALL_FONTS" =~ ^[Yy]$ ]]; then
    # install fonts
    wait_for_apt
    apt-get install $APT_FLAGS fonts-liberation fonts-freefont-ttf
    if [[ "$INSTALL_MS_FONTS" =~ ^[Yy]$ ]]; then
        echo ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true | debconf-set-selections
        apt-get install $APT_FLAGS ttf-mscorefonts-installer
    fi
    fc-cache -f -v
else
    echo "Skipping fonts installation."
fi


echo ""
echo "--- 23. Install Python 3.14 ---"
if [[ "$INSTALL_CPYTHON314" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_CPYTHON314" == 'reinstall' ]]; then
        echo "Uninstall Python 3.14"
        wait_for_apt
        apt-get purge -y python3.14-full python3.14-venv pipx || true
    fi

    if [[ "$VERSION_ID" == "24.04" ]]; then
        # On Ubuntu 24.04, system python is 3.12. Install 3.14 via deadsnakes PPA.
        wait_for_apt
        add-apt-repository -y ppa:deadsnakes/ppa
        apt-get update && apt-get install $APT_FLAGS python3.14-full python3.14-venv pipx

        # Keep 3.12 as default, 3.14 available explicitly via python3.14
        if command -v python3.12 &>/dev/null; then
            update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 2
            update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.14 1
        fi

    elif [[ "$VERSION_ID" == "26.04" ]]; then
        # On Ubuntu 26.04, system python is 3.14. Just ensure venv and pipx are present.
        wait_for_apt
        apt-get update && apt-get install $APT_FLAGS python3.14-venv pipx
    fi

    # Install virtualenv globally via pipx
    # pipx installs tools in isolated pockets, avoiding conflicts with system python
    pipx install virtualenv --include-deps --force

    VIRTUALENV_BIN=$(find /root/.local/bin /usr/local/bin -name virtualenv 2>/dev/null | head -n1)
    if [[ -n "$VIRTUALENV_BIN" && "$VIRTUALENV_BIN" != "/usr/local/bin/virtualenv" ]]; then
        ln -sf "$VIRTUALENV_BIN" /usr/local/bin/virtualenv
    fi

    # Note: setuptools and wheel are NOT installed here at the system level.
    # Install them inside individual venvs as needed:
    #   python3.14 -m venv /path/to/venv
    #   source /path/to/venv/bin/activate
    #   pip install setuptools wheel

    echo "Python 3.14 and packaging tools (pipx/virtualenv) installed."
else
    echo "Skipping Python 3.14 installation."
fi


echo ""
echo "--- 24. Install PyPy 3.11 ---"
if [[ "$INSTALL_PYPY311" =~ ^[Yy]$ ]]; then

    # Fetch latest PyPy 3.11 version dynamically, fall back to known version if unavailable
    PYPY_BASE_URL="https://downloads.python.org/pypy"
    PYPY_FILENAME=$(curl -fsSL https://downloads.python.org/pypy/versions.json | grep -oP 'pypy3\.11-v[\d.]+-linux64\.tar\.bz2' | sort -V | tail -n1) || true
    if [[ -z "$PYPY_FILENAME" ]]; then
        echo "Could not determine latest PyPy 3.11 version. Falling back to $PYPY_VERSION."
        PYPY_FILENAME="${PYPY_VERSION}.tar.bz2"
    fi

    PYPY_DIRNAME="${PYPY_FILENAME%.tar.bz2}"
    echo "Installing PyPy 3.11 ($PYPY_DIRNAME) to /opt"
    pushd /opt > /dev/null

    if [ ! -d /opt/$PYPY_DIRNAME ]; then
        wget -q $PYPY_BASE_URL/$PYPY_FILENAME
        tar -xjf $PYPY_FILENAME
        rm $PYPY_FILENAME || true
    fi
    ln -sf /opt/$PYPY_DIRNAME/bin/pypy3 /usr/local/bin/pypy3.11
    ln -sf /opt/$PYPY_DIRNAME/bin/pypy3 /usr/local/bin/pypy3
    ln -sf /opt/$PYPY_DIRNAME/bin/pypy3 /usr/local/bin/pypy

    # Bootstrap pip for pypy - safe as this is isolated from the system Python
    /usr/local/bin/pypy3.11 -m ensurepip
    /usr/local/bin/pypy3.11 -m pip install --upgrade --root-user-action=ignore pip virtualenv

    # Note: setuptools and wheel are NOT installed here at the system level.
    # Install them inside individual venvs as needed:
    #   pypy3.11 -m venv /path/to/venv
    #   source /path/to/venv/bin/activate
    #   pip install setuptools wheel

    popd > /dev/null
    echo "PyPy 3.11 installation complete."
else
    echo "Skipping PyPy installation."
fi


echo ""
echo "--- 25. Install weasyprint ---"
if [[ "$INSTALL_WEASYPRINT" =~ ^[Yy]$ ]]; then
    wait_for_apt
    apt-get install $APT_FLAGS weasyprint
else
    echo "Skipping weasyprint installation."
fi


echo ""
echo "--- 26. Install imagemagick ---"
if [[ "$INSTALL_IMAGEMAGICK" =~ ^[Yy]$ ]]; then
    wait_for_apt
    apt-get install $APT_FLAGS imagemagick
else
    echo "Skipping imagemagick installation."
fi


echo ""
echo "--- 27. Install nginx ---"
if [[ "$INSTALL_NGINX" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_NGINX" == 'reinstall' ]]; then
        echo "Uninstall nginx"
        wait_for_apt
        apt-get purge -y nginx || true
    fi
    wait_for_apt
    # apache2-utils needed for htpasswd utility
    apt-get install $APT_FLAGS nginx apache2-utils
    usermod -a -G $USER_SUDO_USER_USERNAME www-data
    systemctl enable --now nginx || true

    if command -v ufw >/dev/null && ufw status | grep -q active; then
        ufw allow 80/tcp
        ufw allow 443/tcp
    fi
else
    echo "Skipping nginx installation."
fi


echo ""
echo "--- 28. Install Valkey ---"
if [[ "$INSTALL_VALKEY" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_VALKEY" == 'reinstall' ]]; then
        echo "Uninstall valkey-server valkey-tools"
        wait_for_apt
        apt-get purge -y valkey-server valkey-tools || true
    fi
    wait_for_apt
    apt-get install $APT_FLAGS valkey-server valkey-tools
    systemctl enable --now valkey-server || true
else
    echo "Skipping Valkey installation."
fi


echo ""
echo "--- 29. Install MySQL ---"
if [[ "$INSTALL_MYSQL" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_MYSQL" == 'reinstall' ]]; then
        echo "Uninstall mysql-server mysqltuner mysql-shell"
        apt-get purge -y mysql-server mysqltuner || true
    fi

    wait_for_apt
    apt-get install $APT_FLAGS mysql-server mysqltuner mysql-shell
    systemctl enable --now mysql.service || echo "Warning: service failed to start"

    # Wait for MySQL to create the socket file before proceeding
    echo "Waiting for MySQL to start..."
    MYSQL_READY=0
    for i in {1..6}; do
        if [ -S /var/run/mysqld/mysqld.sock ]; then
            MYSQL_READY=1
            break
        fi
        sleep 1
    done

    if [ "$MYSQL_READY" -ne 1 ]; then
        echo "Error: MySQL failed to start"
        exit 1
    fi

    # Secure MySQL using the provided password
    mysql_root <<EOS
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${MYSQL_PASS_ESCAPED}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOS

    mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql_root mysql

    # Clear the variable from memory for security
    unset MYSQL_PASS
    #unset MYSQL_PASS_CONFIRM
    unset MYSQL_PASS_ESCAPED
    echo "MySQL root password set and security initialized."
else
    echo "Skipping MySQL installation."
fi


echo ""
echo "--- 30. Install PostgreSQL $PG_VERSION ---"
if [[ "$INSTALL_POSTGRESQL" =~ ^[Yy]$ ]]; then

    if [[ "$PROMPT_POSTGRESQL" == 'reinstall' ]]; then
        echo "Uninstall postgresql-$PG_VERSION postgresql-client-$PG_VERSION"
        apt-get purge -y postgresql-$PG_VERSION-pgaudit postgresql-$PG_VERSION-postgis-3 || true
        apt-get purge -y postgresql-client-$PG_VERSION || true
        apt-get purge -y postgresql-$PG_VERSION || true
        rm -rf /var/lib/postgresql/* || true
    fi

    # Remove Ubuntu 26.04 posgresql-17 and postgresql-17
    apt-get purge -y postgresql-16 || true
    apt-get purge -y postgresql-17 || true

    # Add PostgreSQL signing key
    # Keys for 3rd-party repos go into /etc/apt/keyrings/, not /usr/share/keyrings/ or anywhere else
    rm -f /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg || true
    rm -f /etc/apt/keyrings/postgresql.gpg || true
    rm -f /usr/share/keyrings/postgresql.gpg || true

    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg

    if [[ -f "/etc/apt/keyrings/postgresql.gpg" && -s "/etc/apt/keyrings/postgresql.gpg" ]]; then
        install -d /usr/share/postgresql-common/pgdg

        # Add PostgreSQL repository
        echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] \
        http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list

        # Update package lists
        wait_for_apt
        apt-get update -y

        # Install PostgreSQL 18
        apt-get install $APT_FLAGS postgresql-$PG_VERSION
        apt-get install $APT_FLAGS postgresql-client-$PG_VERSION

        # Optional: Install Useful PostgreSQL Tools
        apt-get install $APT_FLAGS postgresql-$PG_VERSION-pgaudit postgresql-$PG_VERSION-postgis-3

        # Prevent automatically installing v16 by using one of the two:
        # apt-get install $APT_FLAGS postgresql-$PG_VERSION postgresql-client-$PG_VERSION --no-install-recommends
        # apt-get purge -y postgresql-16 || true

        echo "PostgreSQL version installed:"
        psql --version

        # Detect cluster path
        PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
        PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

        echo "Backing up configuration..."
        cp "$PG_CONF" "${PG_CONF}.bak"
        cp "$PG_HBA" "${PG_HBA}.bak"

        echo "Enabling PostgreSQL..."
        systemctl enable --now postgresql || echo "Warning: service failed to start"
    else
        echo "Could not download gpg key. Skipping installation."
    fi
else
    echo "Skipping PostgreSQL installation."
fi


echo ""
echo "--- 31. Install Mosquitto MQTT broker ---"
if [[ "$INSTALL_MOSQUITTO" =~ ^[Yy]$ ]]; then

    if [[ "$PROMPT_MOSQUITTO" == 'reinstall' ]]; then
        echo "Uninstall mosquitto mosquitto-clients"
        wait_for_apt
        apt-get purge -y mosquitto mosquitto-clients  || true
    fi

    wait_for_apt
    apt-get install $APT_FLAGS mosquitto mosquitto-clients
    mkdir -p /var/log/mosquitto/ /var/run/mosquitto/
    chown mosquitto: /var/log/mosquitto

    systemctl enable --now mosquitto.service || echo "Warning: service failed to start"
else
    echo "Skipping Mosquitto MQTT broker installation."
fi


echo ""
echo "--- 32. Install Postfix (relay-only) ---"
if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ ]]; then

    if [[ "$PROMPT_POSTFIX" == 'reinstall' ]]; then
        echo "Uninstall postfix"
        wait_for_apt
        apt-get purge -y postfix mailutils libsasl2-modules || true
        rm -rf /etc/postfix || true
    fi

    wait_for_apt
    apt-get install $APT_FLAGS postfix mailutils libsasl2-modules

    # Postfix config is applied after installation alongside other services.
    # We just ensure the service is enabled here; section 36 restarts it
    # after main.cf and sasl_passwd are in place.
    systemctl enable postfix || echo "Warning: could not enable postfix"
else
    echo "Skipping Postfix installation."
fi


echo ""
echo "--- 33. Install Monit ---"
if [[ "$INSTALL_MONIT" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_MONIT" == 'reinstall' ]]; then
        echo "Uninstall monit"
        rm -rf /etc/monit/conf-enabled
        wait_for_apt
        apt-get purge -y monit  || true
    fi
    wait_for_apt
    apt-get install $APT_FLAGS monit
    systemctl enable --now monit.service || echo "Warning: service failed to start"
else
    echo "Skipping Monit installation."
fi


echo ""
echo "--- 34. Install Webmin ---"
if [[ "$INSTALL_WEBMIN" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_WEBMIN" == 'reinstall' ]]; then
        echo "Uninstall webmin"
        wait_for_apt
        apt-get purge -y webmin || true
    fi

    # Use official Webmin setup script to configure repo and GPG key
    curl -fsSL https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh -o /tmp/webmin-setup-repo.sh || true

    if [[ -f /tmp/webmin-setup-repo.sh && -s /tmp/webmin-setup-repo.sh ]]; then
        sh /tmp/webmin-setup-repo.sh --force
        rm -f /tmp/webmin-setup-repo.sh
        wait_for_apt
        apt-get install $APT_FLAGS webmin --install-recommends
        systemctl enable --now webmin.service || echo "Warning: service failed to start"
    else
        echo "Could not download Webmin setup script. Skipping installation."
    fi
else
    echo "Skipping Webmin installation."
fi


echo ""
echo "--- 35. Install Grafana ---"
if [[ "$INSTALL_GRAFANA" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_GRAFANA" == 'reinstall' ]]; then
        echo "Uninstall grafana"
        wait_for_apt
        apt-get purge -y grafana  || true
        rm -rf /etc/grafana || true
    fi

    # Keys for 3rd-party repos go into /etc/apt/keyrings/, not /usr/share/keyrings/
    mkdir -p /etc/apt/keyrings/
    rm -f /etc/apt/keyrings/grafana.gpg || true
    rm -f /usr/share/keyrings/grafana.gpg || true

    #wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | tee /etc/apt/keyrings/grafana.gpg > /dev/null || true
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg || true
    chmod 644 /etc/apt/keyrings/grafana.gpg

    if [[ -f "/etc/apt/keyrings/grafana.gpg" && -s "/etc/apt/keyrings/grafana.gpg" ]]; then
        echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
        wait_for_apt
        apt-get update
        sleep 1
        wait_for_apt
        apt-get install $APT_FLAGS grafana

        # ensure group grafana exists
        if ! getent group grafana >/dev/null; then
            groupadd grafana
        fi
        usermod -a -G grafana $USER_SUDO_USER_USERNAME
        systemctl enable --now grafana-server.service || echo "Warning: service failed to start"
    else
        echo "Could not download gpg key. Skipping installation."
    fi
else
    echo "Skipping Grafana installation."
fi


echo ""
echo "--- 36. Install Forgejo ---"
if [[ "$INSTALL_FORGEJO" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_FORGEJO" == 'reinstall' ]]; then
        echo "Uninstall forgejo (deleting folders)"
        rm -f /usr/local/bin/forgejo || true
        rm -rf /var/lib/forgejo || true
        rm -rf /etc/forgejo || true
    fi

    if ! id "git" &>/dev/null; then
        echo "Adding user git"
        adduser --system --shell /bin/bash --group --disabled-password --home /home/git git || true
    fi
    if ! getent group git >/dev/null; then
        echo "Adding group git"
        groupadd git
    fi

    echo "Determining latest forgejo version"
    rm -f forgejo-latest || true
    FORGEJO_LATEST=$(curl -s https://codeberg.org/api/v1/repos/forgejo/forgejo/releases/latest | jq -r .tag_name | sed 's/v//')
    echo "Downloading forgejo $FORGEJO_LATEST ..."
    wget -q -O forgejo-latest "https://codeberg.org/forgejo/forgejo/releases/download/v${FORGEJO_LATEST}/forgejo-${FORGEJO_LATEST}-linux-amd64" || true

    if [[ -f "forgejo-latest" &&  -s "forgejo-latest" ]]; then
        install -m 755 forgejo-latest /usr/local/bin/forgejo
        mkdir -p /var/lib/forgejo /etc/forgejo
        echo "Forgejo $FORGEJO_LATEST installed"

        chown git:git /var/lib/forgejo && chmod 750 /var/lib/forgejo
        chown root:git /etc/forgejo && chmod 770 /etc/forgejo
        usermod -a -G git $USER_SUDO_USER_USERNAME

        # cleanup
        rm -f forgejo-latest || true

        # configure
        if [[ "$INSTALL_GRAFANA" =~ ^[Yy]$ || "$ISINSTALLED_GRAFANA" =~ ^[Yy]$ ]]; then
            # Grafana and Forgejo both use port 3000 by default. -> Change Forgejo port
            echo "Installing Forgejo on port $FORGEJO_PORT"
            cat <<EOF > /etc/forgejo/app.ini
[server]
SSH_DOMAIN = $FORGEJO_DOMAIN
DOMAIN = $FORGEJO_DOMAIN
HTTP_PORT = $FORGEJO_PORT
ROOT_URL = http://$FORGEJO_DOMAIN:$FORGEJO_PORT/
EOF
        fi

        # install systemd service script
        echo "Installing Forgejo service script"
        rm -f /etc/systemd/system/forgejo.service || true
        wget -q -O /etc/systemd/system/forgejo.service https://codeberg.org/forgejo/forgejo/raw/branch/forgejo/contrib/systemd/forgejo.service || true
        if [[ -f "/etc/systemd/system/forgejo.service" && -s "/etc/systemd/system/forgejo.service" ]]; then
            systemctl daemon-reload
            systemctl enable --now forgejo.service || echo "Warning: service failed to start"
        else
            echo "Could not download service script. Skipping systemd setup for Forgejo."
        fi
    else
        echo "Could not download gpg key. Skipping installation."
    fi
else
    echo "Skipping Forgejo installation."
fi
if [[ "$ISINSTALLED_FORGEJO" == "y" && -z "${FORGEJO_PORT:-}" ]]; then
    # Resolve FORGEJO_PORT from app.ini if not already set in conf or prompted
    FORGEJO_PORT=$(grep -oP '(?<=HTTP_PORT\s=\s)\d+' /etc/forgejo/app.ini 2>/dev/null || echo "3000")
fi
# Ensure FORGEJO_PORT always has a value to avoid unbound variable errors
FORGEJO_PORT="${FORGEJO_PORT:-3000}"

echo ""
echo "--- 35. Disable TCP Transmit Offloading ---"
if [[ "$DISABLE_TX_OFFLOAD" =~ ^[Yy]$ ]]; then

    if [[ -f $CONFIG_DIR/etc/systemd/system/disable-offload.service ]]; then
        cp $CONFIG_DIR/etc/systemd/system/disable-offload.service /etc/systemd/system/disable-offload.service
        sed -i "s|%%PRIMARY_INTERFACE%%|$PRIMARY_INTERFACE|g" /etc/systemd/system/disable-offload.service
        systemctl daemon-reload
        systemctl enable --now disable-offload.service \
            && echo "TCP transmit offloading disabled on $PRIMARY_INTERFACE." \
            || echo "Warning: could not enable disable-offload service."
    else
        echo "File $CONFIG_DIR/etc/systemd/system/disable-offload.service not found"
    fi
else
    echo "Skipping TCP transmit offload configuration."
fi

echo ""
echo "--- 38. Install Fail2Ban ---"
if [[ "$INSTALL_FAIL2BAN" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_FAIL2BAN" == 'reinstall' ]]; then
        echo "Uninstall fail2ban"
        wait_for_apt
        apt-get purge -y fail2ban  || true
    fi

    wait_for_apt
    apt-get install $APT_FLAGS fail2ban
    cat <<'EOF' > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 1h
bantime.increment = true
bantime.factor = 2
EOF
    systemctl enable --now fail2ban.service
else
    echo "Skipping Fail2Ban installation."
fi


echo ""
echo "--- 39. Install auditd ---"
if [[ "$INSTALL_AUDITD" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_AUDITD" == 'reinstall' ]]; then
        echo "Uninstall auditd"
        wait_for_apt
        apt-get purge -y auditd  || true
    fi

    wait_for_apt
    apt-get install $APT_FLAGS auditd
    systemctl enable --now auditd.service || echo "Warning: service failed to start"

    # Configuring Auditd Rules for Wazuh
    # Install a basic set of rules (e.g., tracking execve, file deletions, etc.)
    curl -s https://raw.githubusercontent.com/Neo23x0/auditd/master/audit.rules -o /etc/audit/rules.d/audit.rules

    # FIX: Comment out rules for users that don't exist on this system
    # This prevents the "Unknown user" errors from breaking the rule load
    sed -i 's/^-a always,exit -F arch=b64 -S connect -F auid>=1000 -F auid!=4294967295 -F key=export/#&/' /etc/audit/rules.d/audit.rules
    sed -i '/-u chrony/s/^/#/' /etc/audit/rules.d/audit.rules
    sed -i '/-u ntp/s/^/#/' /etc/audit/rules.d/audit.rules

    augenrules --load

    echo "Verify auditd rules are loaded (this should show a long list without errors)"
    auditctl -l | head -n 20 || true
else
    echo "Skipping auditd installation."
fi


echo ""
echo "--- 40. Install ip blocklist (ipset + ipsum) ---"
if [[ "$INSTALL_IPBLOCK" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_IPBLOCK" == 'reinstall' ]]; then
        echo "Uninstall ip blocklist"

        if [[ -f /etc/ufw/after.init.orig  && -s /etc/ufw/after.init.orig ]]; then
            # restore backup
            cp /etc/ufw/after.init.orig /etc/ufw/after.init || true
        fi
        rm -f /etc/cron.daily/ufw-blocklist-ipsum || true
        rm -f /etc/ipsum.4.txt || true

        # Remove iptables rules referencing the blocklist chains from parent chains
        for chain in INPUT FORWARD OUTPUT; do
            while true; do
                RULENUM=$(iptables -L "$chain" -n --line-numbers 2>/dev/null | grep "ufw-blocklist" | awk '{print $1}' | head -n1) || true
                if [[ -z "$RULENUM" ]]; then break; fi
                iptables -D "$chain" "$RULENUM" 2>/dev/null || break
            done
        done

        # Flush and delete the blocklist chains
        for chain in ufw-blocklist-input ufw-blocklist-forward ufw-blocklist-output; do
            iptables -F "$chain" 2>/dev/null || true
            iptables -X "$chain" 2>/dev/null || true
        done

        # Now safe to destroy the ipset
        ipset flush ufw-blocklist-ipsum 2>/dev/null || true
        ipset destroy ufw-blocklist-ipsum 2>/dev/null || true

        echo "Remaining setlist:"
        ipset list -n || true
    fi

    wait_for_apt
    apt-get install $APT_FLAGS ipset

    # Backup the original ufw after.init if not already backed up
    if [ ! -f /etc/ufw/after.init.orig ]; then
        cp /etc/ufw/after.init /etc/ufw/after.init.orig
    fi

    # Use a temporary directory for the git clone
    TEMP_DIR=$(mktemp -d)
    git clone https://github.com/poddmo/ufw-blocklist.git "$TEMP_DIR"

    # Install the ufw-blocklist files
    if [ -f "$TEMP_DIR/after.init" ]; then
        cp "$TEMP_DIR/after.init" /etc/ufw/after.init
        chown root:root /etc/ufw/after.init
        chmod 750 /etc/ufw/after.init
    fi
    if [ -f "$TEMP_DIR/ufw-blocklist-ipsum" ]; then
        cp "$TEMP_DIR/ufw-blocklist-ipsum" /etc/cron.daily/ufw-blocklist-ipsum
        chown root:root /etc/cron.daily/ufw-blocklist-ipsum
        chmod 750 /etc/cron.daily/ufw-blocklist-ipsum
    fi

    # Download an initial IP blocklist from IPsum (Level 4: IPs found in 4+ blacklists)
    curl -sS -f --compressed -o /etc/ipsum.4.txt 'https://raw.githubusercontent.com/stamparm/ipsum/master/levels/4.txt'
    chmod 640 /etc/ipsum.4.txt

    # Clean up temp directory
    rm -rf "$TEMP_DIR"

    # Initialize ipset and reload UFW to apply the blocklist
    /etc/ufw/after.init start

    # Ensure UFW is reloaded to recognize the new after.init logic
    ufw reload
else
    echo "Skipping IP blocklist installation."
fi


echo ""
echo "--- 41. Install Suricata IDS ---"
if [[ "$INSTALL_SURICATA" =~ ^[Yy]$ ]]; then
    # The idea is that wazuh agent monitors /var/log/suricata/eve.json for attacks and responses are configured and triggered via wazuh manager

    if [[ "$PROMPT_SURICATA" == 'reinstall' ]]; then
        echo "Uninstall suricata"
        # Backup original config

        if [[ -f /etc/suricata/suricata.yaml ]]; then
          cp /etc/suricata/suricata.yaml /etc/suricata/suricata.yaml.bak
        fi
        wait_for_apt
        apt-get purge -y suricata suricata-update  || true
        rm -rf /etc/suricata || true

        rm -rf /var/run/suricata || true
        rm -rf /var/log/suricata || true
        rm -rf var/lib/suricata || true
        rm -rf /usr/lib/suricata || true
    fi

    if [[ "$VERSION_ID" == "24.04" ]]; then
        # Use official Suricata PPA for Ubuntu 24.04
        wait_for_apt
        add-apt-repository -y ppa:oisf/suricata-stable
        apt-get update
    fi

    # FIX: Remove the standalone suricata-update first to avoid the overwrite conflict
    # Then install suricata with a 'force-overwrite' flag just in case
    wait_for_apt
    apt-get purge -y suricata-update
    apt-get install $APT_FLAGS -o Dpkg::Options::="--force-overwrite" suricata

    # Configure Suricata to use the correct network interface. Commented, because seems to be taken care of by 'apt-get install'
    # Update the interface in the config file
    # echo "Configure suricate to use interface $PRIMARY_INTERFACE"
    # sed -i "s/interface: eth0/interface: $PRIMARY_INTERFACE/g" /etc/suricata/suricata.yaml
    # sed -i "s/^\s*-\s*interface:.*/  - interface: $PRIMARY_INTERFACE/" /etc/suricata/suricata.yaml
    sed -i "s/interface: .*/interface: $PRIMARY_INTERFACE/" /etc/suricata/suricata.yaml

    # Enable community-id for easier log correlation with other tools
    sed -i 's/community-id: false/community-id: true/' /etc/suricata/suricata.yaml

    # Update rules. Installs /var/lib/suricata/rules/suricata.rules
    suricata-update --no-test || true

    echo "Verify suricata config file /etc/suricata/suricata.yaml"
    suricata -T -c /etc/suricata/suricata.yaml || echo "Warning: Suricata config test returned warnings"

    # Enable and start service
    systemctl enable --now suricata.service || echo "Warning: service failed to start"

    # Verify Suricata is running in IDS mode
    systemctl status suricata --no-pager -l | head -n 20
    echo "Suricata installed on interface: $PRIMARY_INTERFACE. Logs at /var/log/suricata/eve.json"

    # Note To watch live what's going on, run:
    # tail -f /var/log/suricata/eve.json | jq
else
    echo "Skipping Suricata IDS installation."
fi


echo ""
echo "--- 42. Install and configure Wazuh Agent ---"
if [[ "$INSTALL_WAZUH" =~ ^[Yy]$ ]]; then

    if [[ "$PROMPT_WAZUH" == 'reinstall' ]]; then
        echo "Uninstall wazuh-agent"
        wait_for_apt
        apt-get purge -y wazuh-agent || true
    fi

    if [ -n "$WAZUH_MANAGER" ]; then

        # Keys for 3rd-party repos go into /etc/apt/keyrings/, not /usr/share/keyrings/
        # Setup Keyring
        mkdir -p /etc/apt/keyrings

        # Add Wazuh Repository
        rm -f /etc/apt/keyrings/wazuh.gpg || true
        rm -f /usr/share/keyrings/wazuh.gpg || true

        curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /etc/apt/keyrings/wazuh.gpg || true
        if [[ -f "/etc/apt/keyrings/wazuh.gpg" &&  -s "/etc/apt/keyrings/wazuh.gpg" ]]; then
            echo "deb [signed-by=/etc/apt/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
            apt-get update

            wait_for_apt
            apt-get install $APT_FLAGS wazuh-agent

            # Configure Manager Address
            sed -i "s/<address>MANAGER_IP<\/address>/<address>$WAZUH_MANAGER<\/address>/" /var/ossec/etc/ossec.conf

            # Define the log paths correctly
            # Note: We use a temporary file to hold the XML block
            cat <<'EOF' > /tmp/wazuh_logs.xml
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/suricata/eve.json</location>
  </localfile>
  <localfile>
    <log_format>audit</log_format>
    <location>/var/log/audit/audit.log</location>
  </localfile>
EOF

            # Clean up any previous failed attempts to avoid duplicates/errors
            #sed -i '/\/var\/log\/suricata\/eve.json/d' /var/ossec/etc/ossec.conf
            #sed -i '/\/var\/log\/audit\/audit.log/d' /var/ossec/etc/ossec.conf

            # Insert the block BEFORE the very first closing </ossec_config> tag
            # This ensures it stays within the global config but outside sub-blocks
            if ! grep -q "/var/log/suricata/eve.json" /var/ossec/etc/ossec.conf; then
                sed -i "/<\/ossec_config>/e cat /tmp/wazuh_logs.xml" /var/ossec/etc/ossec.conf
            fi

            rm -f /tmp/wazuh_logs.xml || true

            systemctl enable --now wazuh-agent.service || echo "Warning: service failed to start"
        else
            echo "Could not download gpg key. Skipping installation."
        fi
    else
        echo "No Manager IP provided. Skipping installation."
    fi
else
    echo "Skipping Wazuh Agent installation."
fi


echo ""
echo "--- 43 Configure AppArmor ---"
if [[ "$CONFIGURE_APPARMOR" =~ ^[Yy]$ ]]; then

    # Always ensure utilities and profiles are installed
    wait_for_apt
    apt-get install $APT_FLAGS apparmor apparmor-utils apparmor-profiles apparmor-profiles-extra

    if [[ "$APPARMOR_ENABLE" =~ ^[Yy]$ ]]; then
        # Ensure AppArmor is enabled in grub if not already
        if ! grep -q "apparmor=1" /etc/default/grub; then
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 apparmor=1 security=apparmor"/' /etc/default/grub
            update-grub
        fi
        systemctl enable --now apparmor || echo "Warning: could not enable AppArmor"
        echo "  AppArmor enabled."
    else
        systemctl disable apparmor || true
        echo "  AppArmor disabled."
    fi

    if [[ "$APPARMOR_ENABLE" =~ ^[Yy]$ && "$APPARMOR_ENFORCE" =~ ^[Yy]$ ]]; then
        echo "  Setting available profiles to enforce mode..."

        # Enforce all profiles that exist on disk — works across Ubuntu 24 and 26
        # since profile availability differs between releases
        for PROFILE in \
            "usr.sbin.mysqld" \
            "usr.sbin.rsyslogd" \
            "mosquitto" \
            "usr.sbin.nginx" \
            "usr.sbin.sshd"; do
            if [[ -f "/etc/apparmor.d/$PROFILE" ]]; then
                aa-enforce "/etc/apparmor.d/$PROFILE" \
                    && echo "  [V] $PROFILE: enforce" \
                    || echo "  [!] $PROFILE: failed to enforce"
            else
                echo "  [-] $PROFILE: no profile available on this release"
            fi
        done

        # For installed services without profiles, generate a minimal profile
        # and set to complain mode so aa-logprof can build a proper profile
        # from real usage. Run aa-logprof after normal use, then aa-enforce.
        echo ""
        echo "  Setting installed services without profiles to complain mode..."
        declare -A APPARMOR_SERVICE_MAP=(
            ["/usr/sbin/nginx"]="nginx"
            ["/usr/sbin/postfix"]="postfix"
            ["/usr/lib/postgresql/$PG_VERSION/bin/postgres"]="postgresql"
            ["/usr/bin/grafana-server"]="grafana-server"
            ["/usr/bin/forgejo"]="forgejo"
        )
        for SERVICE_BIN in "${!APPARMOR_SERVICE_MAP[@]}"; do
            SERVICE="${APPARMOR_SERVICE_MAP[$SERVICE_BIN]}"
            # Skip if binary not installed
            [[ ! -f "$SERVICE_BIN" ]] && continue
            # Skip if service not running
            systemctl is-active --quiet "$SERVICE" 2>/dev/null || continue
            # Skip if profile already loaded
            if aa-status 2>/dev/null | grep -qF "$SERVICE_BIN"; then
                echo "  [-] $(basename $SERVICE_BIN): profile already loaded, skipping"
                continue
            fi
            # Generate minimal profile and set to complain mode
            aa-genprof "$SERVICE_BIN" -f /dev/null 2>/dev/null || true
            aa-complain "$SERVICE_BIN" 2>/dev/null \
                && echo "  [~] $(basename $SERVICE_BIN): complain mode (run sudo aa-logprof after normal use)" \
                || echo "  [!] $(basename $SERVICE_BIN): failed to set complain mode"
        done

        # Summary
        echo ""
        echo "  AppArmor status summary:"
        aa-status 2>/dev/null | grep -E "profiles are in enforce|profiles are in complain|processes are in enforce|processes are unconfined"

    elif [[ "$APPARMOR_ENABLE" =~ ^[Yy]$ ]]; then
        echo "  Leaving profiles in complain mode."
        aa-status 2>/dev/null | grep -E "profiles are in enforce|profiles are in complain"
    fi
else
    echo "Skipping AppArmor configuration."
fi


echo ""
echo "--- 44. Install configuration files ---"

# Re-detect installed services now that installation is complete.
# This updates ISINSTALLED_ variables to include services installed during this run,
# so config files, Monit links, and restarts apply to all currently installed services.
echo "Detecting installed services (post-install):"
check_service nginx PROMPT_NGINX ISINSTALLED_NGINX
check_service valkey-server PROMPT_VALKEY ISINSTALLED_VALKEY
check_service mysql PROMPT_MYSQL ISINSTALLED_MYSQL
check_service postgresql PROMPT_POSTGRESQL ISINSTALLED_POSTGRESQL
check_service mosquitto PROMPT_MOSQUITTO ISINSTALLED_MOSQUITTO
check_service postfix PROMPT_POSTFIX ISINSTALLED_POSTFIX
check_service monit PROMPT_MONIT ISINSTALLED_MONIT
check_service webmin PROMPT_WEBMIN ISINSTALLED_WEBMIN
check_service grafana-server PROMPT_GRAFANA ISINSTALLED_GRAFANA
check_service forgejo PROMPT_FORGEJO ISINSTALLED_FORGEJO
check_service fail2ban PROMPT_FAIL2BAN ISINSTALLED_FAIL2BAN
check_service auditd PROMPT_AUDITD ISINSTALLED_AUDITD
check_service suricata PROMPT_SURICATA ISINSTALLED_SURICATA
check_service wazuh-agent PROMPT_WAZUH ISINSTALLED_WAZUH


if [[ "$INSTALL_MYSQL" =~ ^[Yy]$ ]]; then
    echo "  Copying MySQL config files"

    if [[ -f $CONFIG_DIR/etc/mysql/mysql.conf.d/mysqld.cnf ]]; then
        cp $CONFIG_DIR/etc/mysql/mysql.conf.d/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf

        sed -i "s|%%INNODB_BUFFER_POOL_SIZE%%|${MYSQL_BUFFER_POOL_MB}M|g"            /etc/mysql/mysql.conf.d/mysqld.cnf
        sed -i "s|%%INNODB_BUFFER_POOL_INSTANCES%%|${MYSQL_BUFFER_POOL_INSTANCES}|g"  /etc/mysql/mysql.conf.d/mysqld.cnf
        sed -i "s|%%INNODB_BUFFER_POOL_CHUNK_SIZE%%|${MYSQL_BUFFER_POOL_CHUNK_MB}M|g" /etc/mysql/mysql.conf.d/mysqld.cnf
        sed -i "s|%%MAX_CONNECTIONS%%|${MYSQL_MAX_CONNECTIONS}|g"                    /etc/mysql/mysql.conf.d/mysqld.cnf
        sed -i "s|%%INNODB_LOG_BUFFER_SIZE%%|${MYSQL_LOG_BUFFER_MB}M|g"              /etc/mysql/mysql.conf.d/mysqld.cnf
        sed -i "s|%%BINLOG_CACHE_SIZE%%|${MYSQL_BINLOG_CACHE_MB}M|g"                 /etc/mysql/mysql.conf.d/mysqld.cnf
        sed -i "s|%%JOIN_BUFFER_SIZE%%|${MYSQL_JOIN_BUFFER_KB}K|g"                   /etc/mysql/mysql.conf.d/mysqld.cnf
        sed -i "s|%%SORT_BUFFER_SIZE%%|${MYSQL_SORT_BUFFER_KB}K|g"                   /etc/mysql/mysql.conf.d/mysqld.cnf
        sed -i "s|%%READ_BUFFER_SIZE%%|${MYSQL_READ_BUFFER_KB}K|g"                   /etc/mysql/mysql.conf.d/mysqld.cnf
        sed -i "s|%%READ_RND_BUFFER_SIZE%%|${MYSQL_READ_RND_BUFFER_KB}K|g"           /etc/mysql/mysql.conf.d/mysqld.cnf
    fi

    if [[ -f $CONFIG_DIR/etc/systemd/system/mysql.service.d/override.conf ]]; then
        # limits.conf changes only apply to PAM-authenticated sessions. Services managed by systemd use their own LimitNOFILE directives in their unit files.
        mkdir -p /etc/systemd/system/mysql.service.d
        cp $CONFIG_DIR/etc/systemd/system/mysql.service.d/override.conf /etc/systemd/system/mysql.service.d/override.conf
    fi
fi

if [[ "$INSTALL_NGINX" =~ ^[Yy]$ ]]; then
    echo "  Copying Nginx config files"
    if [[ -f $CONFIG_DIR/etc/nginx/nginx/nginx.conf ]]; then
        cp $CONFIG_DIR/etc/nginx/nginx.conf /etc/nginx/nginx.conf
        NGINX_WORKER_PROCESSES=${NGINX_WORKER_PROCESSES:-$PROCESSOR_COUNT}
        sed -i "s|%%NGINX_WORKER_PROCESSES%%|$NGINX_WORKER_PROCESSES|g" /etc/nginx/nginx.conf
    fi

    if [[ -f $CONFIG_DIR/etc/nginx/sites-available/default ]]; then
        cp $CONFIG_DIR/etc/nginx/sites-available/default /etc/nginx/sites-available/default
    fi

    if [[ -f $CONFIG_DIR/etc/systemd/system/nginx.service.d/override.conf ]]; then
        # limits.conf changes only apply to PAM-authenticated sessions. Services managed by systemd use their own LimitNOFILE directives in their unit files.
        mkdir -p /etc/systemd/system/nginx.service.d
        cp $CONFIG_DIR/etc/systemd/system/nginx.service.d/override.conf /etc/systemd/system/nginx.service.d/override.conf
    fi
fi

if [[ "$INSTALL_VALKEY" =~ ^[Yy]$ ]]; then
    echo "  Copying Valkey config files"
    if [[ -f $CONFIG_DIR/etc/valkey/valkey.conf ]]; then
        cp $CONFIG_DIR/etc/valkey/valkey.conf /etc/valkey/valkey.conf
    fi
fi

if [[ "$INSTALL_POSTGRESQL" =~ ^[Yy]$ ]]; then
    echo "  Copying PostgreSQL config files"
    PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
    PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

    if [[ -f $CONFIG_DIR/etc/postgresql/postgresql.conf ]]; then
        cp $CONFIG_DIR/etc/postgresql/postgresql.conf "$PG_CONF"

        sed -i "s|%%PG_MAX_CONNECTIONS%%|$PG_MAX_CONNECTIONS|g"                  "$PG_CONF"
        sed -i "s|%%PG_SHARED_BUFFERS%%|${PG_SHARED_BUFFERS_MB}MB|g"             "$PG_CONF"
        sed -i "s|%%PG_WORK_MEM%%|${PG_WORK_MEM_MB}MB|g"                        "$PG_CONF"
        sed -i "s|%%PG_EFFECTIVE_CACHE_SIZE%%|${PG_EFFECTIVE_CACHE_MB}MB|g"      "$PG_CONF"
        sed -i "s|%%PG_MAX_WORKER_PROCESSES%%|$PG_MAX_WORKER_PROCESSES|g"        "$PG_CONF"
        sed -i "s|%%PG_MAX_PARALLEL_WORKERS%%|$PG_MAX_PARALLEL_WORKERS|g"        "$PG_CONF"
        sed -i "s|%%PG_MAX_PARALLEL_WORKERS_PG%%|$PG_MAX_PARALLEL_WORKERS_PG|g"  "$PG_CONF"
        sed -i "s|%%PG_EFFECTIVE_IO_CONCURRENCY%%|$PG_EFFECTIVE_IO_CONCURRENCY|g" "$PG_CONF"
    fi

    if [[ -f $CONFIG_DIR/etc/postgresql/pg_hba.conf ]]; then
        cp $CONFIG_DIR/etc/postgresql/pg_hba.conf "$PG_HBA"
    fi

    if [[ -f $CONFIG_DIR/etc/systemd/system/postgresql.service.d/override.conf ]]; then
        # limits.conf changes only apply to PAM-authenticated sessions. Services managed by systemd use their own LimitNOFILE directives in their unit files.
        mkdir -p /etc/systemd/system/postgresql.service.d
        cp $CONFIG_DIR/etc/systemd/system/postgresql.service.d/override.conf /etc/systemd/system/postgresql.service.d/override.conf
    fi

    # Set superuser password (PostgreSQL must be running)
    echo "  Setting PostgreSQL superuser password..."
    PG_PASS_ESCAPED=$(printf "%s" "$PG_PASS" | sed "s/'/''/g")
    sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '${PG_PASS_ESCAPED}';" || true

    # Clear the variable from memory for security
    unset PG_PASS
    unset PG_PASS_ESCAPED
fi

if [[ "$INSTALL_GRAFANA" =~ ^[Yy]$ ]]; then
    echo "  Copying Grafana config files"

    if [[ -f $CONFIG_DIR/etc/grafana/grafana.ini ]]; then
        cp $CONFIG_DIR/etc/grafana/grafana.ini /etc/grafana/grafana.ini

        GRAFANA_RANDOM_SECRET=$(openssl rand -hex 32)
        sed -i "s|%%GRAFANA_RANDOM_SECRET%%|$GRAFANA_RANDOM_SECRET|g"            /etc/grafana/grafana.ini
        sed -i "s|%%GRAFANA_SMTP_ENABLED%%|$GRAFANA_SMTP_ENABLED|g"              /etc/grafana/grafana.ini
        sed -i "s|%%GRAFANA_SMTP_HOST%%|$GRAFANA_SMTP_HOST|g"                    /etc/grafana/grafana.ini
        sed -i "s|%%GRAFANA_SMTP_PORT%%|$GRAFANA_SMTP_PORT|g"                    /etc/grafana/grafana.ini
        sed -i "s|%%GRAFANA_SMTP_USER%%|$GRAFANA_SMTP_USER|g"                    /etc/grafana/grafana.ini
        sed -i "s|%%GRAFANA_SMTP_PASSWORD%%|$GRAFANA_SMTP_PASSWORD|g"            /etc/grafana/grafana.ini
        sed -i "s|%%GRAFANA_SMTP_FROM_ADDRESS%%|$GRAFANA_SMTP_FROM_ADDRESS|g"    /etc/grafana/grafana.ini
        sed -i "s|%%GRAFANA_SMTP_FROM_NAME%%|$GRAFANA_SMTP_FROM_NAME|g"          /etc/grafana/grafana.ini
        sed -i "s|%%GRAFANA_SMTP_EHLO_IDENTITY%%|$GRAFANA_SMTP_EHLO_IDENTITY|g"  /etc/grafana/grafana.ini
        sed -i "s|%%GRAFANA_SMTP_STARTTLS_POLICY%%|$GRAFANA_SMTP_STARTTLS_POLICY|g" /etc/grafana/grafana.ini
    fi
fi

if [[ "$INSTALL_FORGEJO" =~ ^[Yy]$ ]]; then
    echo "  Copying Forgejo config files"
    if [[ -f $CONFIG_DIR/etc/forgejo/app.ini ]]; then
        cp $CONFIG_DIR/etc/forgejo/app.ini /etc/forgejo/app.ini

        sed -i "s|%%FORGEJO_DOMAIN%%|$FORGEJO_DOMAIN|g" /etc/forgejo/app.ini
        sed -i "s|%%FORGEJO_PORT%%|$FORGEJO_PORT|g" /etc/forgejo/app.ini
        sed -i "s|%%FORGEJO_MAILER_ENABLED%%|$FORGEJO_MAILER_ENABLED|g" /etc/forgejo/app.ini
        sed -i "s|%%FORGEJO_SMTP_ADDR%%|$FORGEJO_SMTP_ADDR|g"          /etc/forgejo/app.ini
        sed -i "s|%%FORGEJO_SMTP_PORT%%|$FORGEJO_SMTP_PORT|g"          /etc/forgejo/app.ini
        sed -i "s|%%FORGEJO_SMTP_FROM%%|$FORGEJO_SMTP_FROM|g"          /etc/forgejo/app.ini
        sed -i "s|%%FORGEJO_SMTP_USER%%|$FORGEJO_SMTP_USER|g"          /etc/forgejo/app.ini
        sed -i "s|%%FORGEJO_SMTP_PASSWORD%%|$FORGEJO_SMTP_PASSWORD|g"  /etc/forgejo/app.ini

        chown root:git /etc/forgejo/app.ini
        chmod 640 /etc/forgejo/app.ini
    fi
fi

if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ ]]; then
    echo "  Configuring Postfix relay"

    if [[ -f $CONFIG_DIR/etc/postfix/main.cf ]]; then
        cp $CONFIG_DIR/etc/postfix/main.cf /etc/postfix/main.cf

        sed -i "s|%%POSTFIX_RELAY_HOST%%|$POSTFIX_RELAY_HOST|g"      /etc/postfix/main.cf
        sed -i "s|%%POSTFIX_RELAY_PORT%%|$POSTFIX_RELAY_PORT|g"      /etc/postfix/main.cf
        sed -i "s|%%POSTFIX_DOMAIN%%|$POSTFIX_DOMAIN|g"              /etc/postfix/main.cf
        sed -i "s|%%POSTFIX_SERVER_HOSTNAME%%|$LOCAL_HOSTNAME|g"     /etc/postfix/main.cf
    fi

    # Set mailname, otherwise outgoing mail will show the server hostname
    echo "$POSTFIX_DOMAIN" > /etc/mailname || true

    # Write and secure SASL credentials, hash, then delete plaintext
    echo "[$POSTFIX_RELAY_HOST]:$POSTFIX_RELAY_PORT $POSTFIX_RELAY_USERNAME:$POSTFIX_RELAY_PASSWORD" > /etc/postfix/sasl_passwd || true
    chmod 600 /etc/postfix/sasl_passwd || true
    postmap /etc/postfix/sasl_passwd || true
    rm -f /etc/postfix/sasl_passwd || true

    # sender_canonical_maps - rewrites envelope and header sender to FROM address
    echo "/.+/    $POSTFIX_FROM_ADDRESS" > /etc/postfix/sender_canonical_maps
    chmod 644 /etc/postfix/sender_canonical_maps
    postmap /etc/postfix/sender_canonical_maps

    # header_check - rewrites From header to FROM address
    echo "/From:.*/    REPLACE From: $POSTFIX_FROM_ADDRESS" > /etc/postfix/header_check
    chmod 644 /etc/postfix/header_check
    postmap /etc/postfix/header_check

    # generic - maps local user@hostname addresses to external FROM address
    HOSTNAME=$(hostname)
    echo "root@${HOSTNAME}    $POSTFIX_FROM_ADDRESS" > /etc/postfix/generic
    echo "${USER_SUDO_USER_USERNAME}@${HOSTNAME}    $POSTFIX_FROM_ADDRESS" >> /etc/postfix/generic
    chmod 644 /etc/postfix/generic
    postmap /etc/postfix/generic

    # Forward root mail to alias
    if grep -q "^root:" /etc/aliases; then
        sed -i "s|^root:.*|root: $POSTFIX_ROOT_ALIAS|" /etc/aliases
    else
        echo "root: $POSTFIX_ROOT_ALIAS" >> /etc/aliases
    fi
    newaliases

    systemctl enable --now postfix || echo "Warning: could not start postfix"
fi

if [[ "$INSTALL_MONIT" =~ ^[Yy]$ ]]; then
    echo "  Copying Monit config files"

    if [[ -f $CONFIG_DIR/etc/monit/monitrc ]]; then
        cp $CONFIG_DIR/etc/monit/monitrc /etc/monit/monitrc

        sed -i "s|%%MONIT_HOST_NAME%%|$MONIT_HOST_NAME|g"            /etc/monit/monitrc
        sed -i "s|%%MONIT_MAILSERVER_HOST%%|$MONIT_MAILSERVER_HOST|g"    /etc/monit/monitrc
        sed -i "s|%%MONIT_MAILSERVER_PORT%%|$MONIT_MAILSERVER_PORT|g"    /etc/monit/monitrc
        sed -i "s|%%MONIT_MAILSERVER_USERNAME%%|$MONIT_MAILSERVER_USERNAME|g" /etc/monit/monitrc
        sed -i "s|%%MONIT_MAILSERVER_PASSWORD%%|$MONIT_MAILSERVER_PASSWORD|g" /etc/monit/monitrc
        sed -i "s|%%MONIT_ADMIN_USERNAME%%|$MONIT_ADMIN_USERNAME|g"      /etc/monit/monitrc
        sed -i "s|%%MONIT_ADMIN_PASSWORD%%|$MONIT_ADMIN_PASSWORD|g"      /etc/monit/monitrc
        sed -i "s|%%MONIT_ALERT_SENDER%%|$MONIT_ALERT_SENDER|g"          /etc/monit/monitrc
        sed -i "s|%%MONIT_ALERT_RECIPIENT%%|$MONIT_ALERT_RECIPIENT|g"    /etc/monit/monitrc
    fi

    # Set strict permissions since monitrc contains credentials
    chmod 600 /etc/monit/monitrc

    # Copy and link only the conf-available files for installed services
    for SERVICE in \
        "$( [[ "$ISINSTALLED_MYSQL"      == "y" ]] && echo mysql )" \
        "$( [[ "$ISINSTALLED_NGINX"      == "y" ]] && echo nginx )" \
        "$( [[ "$ISINSTALLED_VALKEY"     == "y" ]] && echo valkey-server )" \
        "$( [[ "$ISINSTALLED_POSTGRESQL" == "y" ]] && echo postgresql )" \
        "$( [[ "$ISINSTALLED_MOSQUITTO"  == "y" ]] && echo mosquitto )" \
        "$( [[ "$ISINSTALLED_POSTFIX"    == "y" ]] && echo postfix )" \
        "$( [[ "$ISINSTALLED_WEBMIN"     == "y" ]] && echo webmin )" \
        "$( [[ "$ISINSTALLED_GRAFANA"    == "y" ]] && echo grafana-server )" \
        "$( [[ "$ISINSTALLED_FORGEJO"    == "y" ]] && echo forgejo )" \
        "openssh-server"; do
        [[ -z "$SERVICE" ]] && continue
        SRC="$CONFIG_DIR/etc/monit/conf-available/$SERVICE"
        DEST="/etc/monit/conf-available/$SERVICE"
        LINK="/etc/monit/conf-enabled/$SERVICE"
        if [[ -f "$SRC" ]]; then
            cp "$SRC" "$DEST"
            rm -f "$LINK"
            ln -s "$DEST" /etc/monit/conf-enabled/
        else
            echo "  Warning: Monit config not found for $SERVICE, skipping."
        fi
    done

    # Remove conf-enabled links for services that are no longer installed
    declare -A SERVICE_VAR_MAP=(
        ["mysql"]="ISINSTALLED_MYSQL"
        ["nginx"]="ISINSTALLED_NGINX"
        ["valkey-server"]="ISINSTALLED_VALKEY"
        ["postgresql"]="ISINSTALLED_POSTGRESQL"
        ["mosquitto"]="ISINSTALLED_MOSQUITTO"
        ["postfix"]="ISINSTALLED_POSTFIX"
        ["webmin"]="ISINSTALLED_WEBMIN"
        ["grafana-server"]="ISINSTALLED_GRAFANA"
        ["forgejo"]="ISINSTALLED_FORGEJO"
    )
    for LINK in /etc/monit/conf-enabled/*; do
        [[ -L "$LINK" ]] || continue
        SERVICE=$(basename "$LINK")
        [[ "$SERVICE" == "openssh-server" ]] && continue
        ISINSTALLED_VAR="${SERVICE_VAR_MAP[$SERVICE]:-}"
        if [[ -n "$ISINSTALLED_VAR" && "${!ISINSTALLED_VAR}" == "n" ]]; then
            rm -f "$LINK"
            echo "  Removed Monit link for $SERVICE (no longer installed)"
        fi
    done
fi

# Restart services to apply new configs
echo "  Restarting services to apply configs"
[[ "$ISINSTALLED_MYSQL" == "y" ]]      && systemctl restart mysql           || true
[[ "$ISINSTALLED_NGINX" == "y" ]]      && systemctl restart nginx           || true
[[ "$ISINSTALLED_VALKEY" == "y" ]]     && systemctl restart valkey-server   || true
[[ "$ISINSTALLED_POSTGRESQL" == "y" ]] && systemctl restart postgresql      || true
[[ "$ISINSTALLED_POSTFIX" == "y" ]]    && systemctl restart postfix         || true
[[ "$ISINSTALLED_GRAFANA" == "y" ]]    && systemctl restart grafana-server  || true
[[ "$ISINSTALLED_FORGEJO" == "y" ]]    && systemctl restart forgejo         || true
[[ "$ISINSTALLED_MOSQUITTO" == "y" ]]  && systemctl restart mosquitto       || true
[[ "$ISINSTALLED_MONIT" == "y" ]]      && systemctl restart monit           || true

echo "Configuration files installed."

if [[ "$ISINSTALLED_POSTFIX" == "y" ]]; then
    echo ""
    echo "  Sending Postfix test mail to $POSTFIX_ROOT_ALIAS..."
    echo "Postfix test mail from $(hostname) after provisioning." \
        | mail -s "Postfix Test - $(hostname)" "$POSTFIX_ROOT_ALIAS" \
        && echo "  [V] Test mail sent. Check $POSTFIX_ROOT_ALIAS." \
        || echo "  [!] Test mail failed. Check: sudo tail -n 20 /var/log/mail.log"
fi

echo ""
echo "--- 45. Finalise installation ---"

sysctl --system

apt-get --fix-broken install || true
# Cleanup leftover config packages
# apt-get autoremove -y ; apt-get -y purge $(dpkg --list | grep ^rc | awk '{ print $2; }')
mapfile -t RC_PACKAGES < <(dpkg --list | awk '/^rc/ {print $2}')
if [ ${#RC_PACKAGES[@]} -gt 0 ]; then
    echo "Purging leftover configuration packages: ${RC_PACKAGES[*]}"
    apt-get purge -y "${RC_PACKAGES[@]}" || true
else
    echo "No leftover config packages found."
fi
apt-get -y autoremove || true

echo "Restarting unattended upgrades (takes a while)"
systemctl start apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer || true


echo ""
echo "--- 46. Generating Health Check Script 'ubuntu_health_check.sh' ---"
HEALTH_CHECK_SCRIPT="/home/$USER_SUDO_USER_USERNAME/ubuntu_health_check.sh"
# We start the file with the header and basic checks.
# use 'EOF' to tell bash not to expand variables (e.g. 1, 2, GREEN)
cat <<'EOF' > $HEALTH_CHECK_SCRIPT
#!/bin/bash
# $HEALTH_CHECK_SCRIPT
# XLVISUALS Server Security & Services Health Check

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# --- Function to check service status ---
check_service() {
    local service="$1"
    local name="$2"

    if systemctl status "$service" &>/dev/null; then
        if systemctl is-active --quiet "$service"; then
            echo -e "$name: ${GREEN}[RUNNING]${NC}"
        else
            echo -e "$name: ${RED}[STOPPED]${NC}"
        fi
    else
        echo -e "$name: ${RED}[NOT INSTALLED]${NC}"
    fi
}


echo "==========================================="
echo "      XLVISUALS SERVER HEALTH CHECK "
echo "==========================================="

echo ""
echo "SSH config"
echo "==========================================="
sudo sshd -T | egrep -i 'UsePAM|PermitRootLogin|ChallengeResponseAuthentication|PasswordAuthentication|PermitEmptyPasswords|MaxStartups|LoginGraceTime|MaxAuthTries|PubkeyAuthentication|AllowUsers|ClientAliveCountMax|MaxSessions|AllowTcpForwarding|TCPKeepAlive|X11Forwarding|IgnoreRhosts|AuthenticationMethods|PrintMotd'

echo ""
echo "Swap config"
echo "==========================================="
if [ -n "$(swapon --show)" ]; then
    SWAP_VAL=$(cat /proc/sys/vm/swappiness)
    if [ "$SWAP_VAL" -gt 10 ]; then
        echo "WARNING: Swappiness is set to $SWAP_VAL."
        echo "A value of 10 or lower is recommended for high-performance."
        read -p "Would you like to set swappiness to 10 now? (y/n)" FIX_SWAP
        if [[ "$FIX_SWAP" =~ ^[Yy]$ ]]; then
            sysctl vm.swappiness=10
            # Make it permanent
            if [ -d /etc/sysctl.d ]; then
                echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf
            else
                echo "vm.swappiness=10" >> /etc/sysctl.conf
            fi
            echo "Swappiness optimized to 10."
        fi
    else
        echo "Swappiness is already optimized ($SWAP_VAL)."
    fi
else
    echo "No swap space detected."
fi

echo ""
echo "Disk space"
echo "==========================================="
df -h / | tail -n1 | awk '{print "Used: " $3 " / " $2 " (" $5 " full)"}'

echo ""
echo "Memory"
echo "==========================================="
free -h | awk '/^Mem:/ {print "Used: " $3 " / " $2}'

echo ""
echo "TCP Transmit Offloading"
echo "==========================================="
PRIMARY_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
if systemctl is-active --quiet disable-offload.service; then
    ethtool -k $PRIMARY_INTERFACE 2>/dev/null | grep "tx-checksumming" \
        && echo -e "${GREEN}[DISABLED]${NC}" \
        || echo -e "${RED}[UNKNOWN]${NC}"
else
    echo -e "${NC}[NOT CONFIGURED]${NC}"
fi

echo ""
echo "Failed systemd units"
echo "==========================================="
systemctl --failed --no-legend | grep -v "^$" || echo -e "${GREEN}None${NC}"

echo ""
echo "Recent failed SSH logins"
echo "==========================================="
journalctl _SYSTEMD_UNIT=ssh.service --no-pager -n 5 --grep "Failed|Invalid"

echo ""
echo "Pending updates"
echo "==========================================="
apt-get -s upgrade 2>/dev/null | grep -P "^\d+ upgraded" || echo "Could not check."

echo ""
echo "Service status"
echo "==========================================="
echo -n "UFW Firewall "
ufw status | grep -q "active" && echo -e "${GREEN}[ACTIVE]${NC}" || echo -e "${RED}[INACTIVE]${NC}"
check_service "nginx" "NGINX Web Server"
check_service "valkey-server" "Valkey Server"
check_service "mysql" "MySQL Server"
check_service "postgresql" "PostgreSQL Server"
check_service "mosquitto" "Mosquitto Broker"
check_service "monit" "Monit Server"
check_service "webmin" "Webmin Server"
check_service "grafana-server" "Grafana Server"
check_service "forgejo" "Forgejo Git Server"
check_service "fail2ban" "Fail2Ban IDS"
check_service "auditd" "Auditd Daemon"
check_service "suricata" "Suricata IDS"
check_service "wazuh-agent" "Wazuh Agent"
check_service "postfix" "Postfix Mail Relay"

echo ""
echo "AppArmor"
echo "==========================================="
if command -v aa-status &>/dev/null; then
    if aa-status --enabled 2>/dev/null; then
        aa-status 2>/dev/null | grep -E "profiles are in enforce|profiles are in complain|processes are unconfined"
        echo ""
        echo "Per-service profile status:"

        check_apparmor() {
            local label="$1"
            local profile="$2"
            local service="$3"
            if ! systemctl is-active --quiet "$service" 2>/dev/null; then
                return
            fi
            local aa_out
            aa_out=$(aa-status 2>/dev/null)
            if ! echo "$aa_out" | grep -qF "$profile"; then
                echo -e "  $label: ${RED}[NO PROFILE]${NC}"
                return
            fi
            # Extract section headings and profile names, check which section our profile falls under
            local section
            section=$(echo "$aa_out" | awk -v prof="$profile" '
                /profiles are in enforce mode/  { mode="enforce" }
                /profiles are in complain mode/ { mode="complain" }
                /profiles are in prompt mode/   { mode="prompt" }
                /profiles are in kill mode/     { mode="kill" }
                /profiles are in unconfined/    { mode="unconfined" }
                index($0, prof) && mode != "" { print mode; exit }
            ')
            case "$section" in
                enforce)    echo -e "  $label: ${GREEN}[ENFORCE]${NC}" ;;
                complain)   echo -e "  $label: ${YELLOW}[COMPLAIN]${NC}" ;;
                *)          echo -e "  $label: ${YELLOW}[UNCONFINED]${NC}" ;;
            esac
        }

        check_apparmor "Nginx"          "nginx"              "nginx"
        check_apparmor "MySQL"          "/usr/sbin/mysqld"   "mysql"
        check_apparmor "PostgreSQL"     "postgres"           "postgresql"
        check_apparmor "Valkey"         "valkey"             "valkey-server"
        check_apparmor "Mosquitto"      "mosquitto"          "mosquitto"
        check_apparmor "Postfix"        "postfix"            "postfix"
        check_apparmor "Monit"          "monit"              "monit"
        check_apparmor "Webmin"         "webmin"             "webmin"
        check_apparmor "Grafana"        "grafana"            "grafana-server"
        check_apparmor "Forgejo"        "forgejo"            "forgejo"
        check_apparmor "Fail2Ban"       "fail2ban"           "fail2ban"
        check_apparmor "Auditd"         "auditd"             "auditd"
        check_apparmor "Suricata"       "suricata"           "suricata"
        check_apparmor "Wazuh Agent"    "wazuh"              "wazuh-agent"
        check_apparmor "SSH"            "sshd"               "ssh"
    else
        echo -e "AppArmor: ${RED}[DISABLED]${NC}"
    fi
else
    echo -e "AppArmor: ${RED}[NOT INSTALLED]${NC}"
fi

echo ""
echo "Recent AppArmor denials"
echo "==========================================="
DENIALS=$(grep "apparmor=\"DENIED\"" /var/log/syslog 2>/dev/null \
    | grep -v "ubuntu_pro\|who" \
    | tail -20)
if [[ -n "$DENIALS" ]]; then
    echo "$DENIALS" | grep -oP 'profile="\K[^"]*|operation="\K[^"]*|name="\K[^"]*' \
        | paste - - - | sort | uniq -c | sort -rn
else
    echo "None"
fi

echo ""
echo "Port usage"
echo "==========================================="
ufw_status() {
    local port="$1"
    if ufw status | grep -qE "^${port}(/tcp)?\s+ALLOW"; then
        echo -e "${GREEN}[ALLOWED]${NC}"
    else
        echo -e "${RED}[BLOCKED]${NC}"
    fi
}

check_port() {
    local service="$1"
    local port="$2"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "  $service ($port): $(ufw_status $port)"
    fi
}

check_port "nginx"          "80"
check_port "nginx"          "443"
check_port "mysql"          "3306"
check_port "postgresql"     "5432"
check_port "valkey-server"  "6379"
check_port "mosquitto"      "1883"
check_port "postfix"        "25"
check_port "monit"          "2812"
check_port "grafana-server" "3000"
check_port "forgejo"        "$(grep -oP '(?<=HTTP_PORT\s=\s)\d+' /etc/forgejo/app.ini 2>/dev/null || echo 3000)"
check_port "webmin"         "10000"

echo ""
EOF

chown $USER_SUDO_USER_USERNAME:$USER_SUDO_USER_USERNAME $HEALTH_CHECK_SCRIPT
chmod +x $HEALTH_CHECK_SCRIPT

# Run health check
$HEALTH_CHECK_SCRIPT

echo ""
echo "--- 47. Setup Complete ---"
echo "Logfile written to: $LOG_FILE"
echo "Config backup written to current directory by ubuntu_backup_config.sh"

echo ""
echo "SSH connect command with port forwards:"
SSH_CMD="ssh"
[[ "$ISINSTALLED_MOSQUITTO" =~ ^[Yy]$ ]]  && SSH_CMD="$SSH_CMD -L 1883:localhost:1883"
[[ "$ISINSTALLED_MONIT" =~ ^[Yy]$ ]]      && SSH_CMD="$SSH_CMD -L 2812:localhost:2812"
[[ "$ISINSTALLED_GRAFANA" =~ ^[Yy]$ ]]    && SSH_CMD="$SSH_CMD -L 3000:localhost:3000"
[[ "$ISINSTALLED_FORGEJO" =~ ^[Yy]$ ]]    && SSH_CMD="$SSH_CMD -L ${FORGEJO_PORT}:localhost:${FORGEJO_PORT}"
[[ "$ISINSTALLED_MYSQL" =~ ^[Yy]$ ]]      && SSH_CMD="$SSH_CMD -L 3306:localhost:3306"
[[ "$ISINSTALLED_POSTGRESQL" =~ ^[Yy]$ ]] && SSH_CMD="$SSH_CMD -L 5432:localhost:5432"
[[ "$ISINSTALLED_VALKEY" =~ ^[Yy]$ ]]      && SSH_CMD="$SSH_CMD -L 6379:localhost:6379"
[[ "$ISINSTALLED_WEBMIN" =~ ^[Yy]$ ]]     && SSH_CMD="$SSH_CMD -L 10000:localhost:10000"
SSH_CMD="$SSH_CMD $USER_SUDO_USER_USERNAME@$LOCAL_IP"
echo "$SSH_CMD"


if [[ "$CONFIGURE_APPARMOR" =~ ^[Yy]$ ]]; then
    echo ""
    echo "AppArmor: nginx, postgresql, postfix, grafana set to complain mode."
    echo "After normal use, run: sudo aa-logprof"
    echo "Then to enforce: sudo aa-enforce /etc/apparmor.d/<profile>"
fi

echo ""
echo "ACTION REQUIRED: Test SSH login in a NEW window before closing this one or you may be locked out."
echo "ACTION REQUIRED: Reboot the system to apply all changes."

