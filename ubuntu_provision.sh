#!/bin/bash
#
# UBUNTU 24.04 and 26.04 SERVER PROVISIONING SCRIPT
# by Axel Busch
# 08 June 2026
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
#   - Web stack:    Nginx, MySQL, MariaDB, PostgreSQL, Valkey, Mosquitto
#   - Mail:         Postfix (relay-only; Monit, Grafana, Forgejo can route through it)
#   - Management:   Monit, Grafana, Forgejo, Webmin (not recommended; see README)
#   - Runtimes:     Python 3.14, PyPy 3.11, Weasyprint, ImageMagick
#   - Security:     UFW, Fail2Ban, Suricata, auditd, Wazuh Agent, IP blocklist
#   - Tools:        vim, nano, micro, ne, tmux, btop, ncdu, rsync, dnsutils,
#                   nmap, lynis, git, git-lfs, jq, smartmontools (bare metal only)
#
# MODIFIES (all optional):
#   - System:   LVM resize, swap file, file limits, kernel tuning (sysctl)
#   - Security: SSH hardening (key-only), UFW rules, sudo timeout/NOPASSWD,
#               CIS Level 1 hardening (passwords, PAM, cron, umask, modules,
#               AIDE/Wazuh FIM, core dumps, sysctl, NTP, session timeout)
#   - Timers:   Unattended-upgrades scheduled at prompted UTC hours
#   - User:     Creates or configures a sudo user, sets up SSH key access


## Set package versions and other defaults (or in .conf file)
## --------------------------------------------

PG_VERSION=18
PYPY_FALLBACK_VERSION=pypy3.11-v7.3.23
FORGEJO_FALLBACK_VERSION=15.0.2
MODULEJAIL_FALLBACK_VERSION=1.4.0
FORGEJO_FALLBACK_PORT=3030


## Checks and Utilities
## --------------------------------------------

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "  [!] Please run as root (sudo)"
  exit 1
fi

# Verify Ubuntu 24.04 or 26.04
source /etc/os-release
if [[ "$ID" != "ubuntu" || !("$VERSION_ID" == "24.04" || "$VERSION_ID" == "26.04" ) ]]; then
    echo "  [!] Error: This script is intended for Ubuntu 24.04 and 26.04"
    exit 1
fi

# Read config file if provided
if [[ -n "$1" ]]; then
    if [[ -f "$1" ]]; then
        echo "  Loading configuration from $1"
        source "$1"
    else
        echo "  [!] Error: config file '$1' not found."
        exit 1
    fi
fi

# If INSTALL_DEFAULT is set, apply INSTALL_DEFAULT to any INSTALL_ and CONFIGURE_ variable not explicitly set in conf
if [[ -n "${INSTALL_DEFAULT:-}" ]]; then
    for var in \
        INSTALL_UFW INSTALL_SSH INSTALL_FONTS INSTALL_WEASYPRINT INSTALL_IMAGEMAGICK \
        INSTALL_CPYTHON314 INSTALL_PYPY311 INSTALL_NGINX INSTALL_VALKEY INSTALL_MYSQL \
        INSTALL_MARIADB INSTALL_POSTGRESQL INSTALL_MOSQUITTO INSTALL_POSTFIX INSTALL_MONIT INSTALL_WEBMIN \
        INSTALL_GRAFANA INSTALL_FORGEJO INSTALL_FAIL2BAN INSTALL_AUDITD INSTALL_IPBLOCK \
        INSTALL_SURICATA INSTALL_WAZUHAGENT CREATE_HEALTHSCRIPT; do
        [[ -z "${!var:-}" ]] && printf -v "$var" "$INSTALL_DEFAULT"
    done
    for var in CONFIGURE_LVM CONFIGURE_SWAP CONFIGURE_APPARMOR TUNE_SYSTEM \
               UNINSTALL_PACKAGES UPDATE_PACKAGES INSTALL_PACKAGES \
               DISABLE_TX_OFFLOAD CONFIGURE_MODULEJAIL CONFIGURE_CIS_HARDENING \
               CONFIGURE_UBUNTU_PRO; do
        [[ -z "${!var:-}" ]] && printf -v "$var" "$INSTALL_DEFAULT"
    done
fi

# change into current directory
cd "$(dirname "$(readlink -f "$0")")" || exit

# Config files are expected in the etc subdirectory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR"

# Set system related variables
PROCESSOR_COUNT=$(nproc)
# Detect CPU architecture for architecture-specific downloads
MACHINE_ARCH=$(uname -m)   # e.g. x86_64, aarch64
LOCAL_HOSTNAME=$(hostname -f)
LOCAL_IP=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+')
REAL_USER=${SUDO_USER:-$(logname 2>/dev/null)}
USER_SUDO_USER_USERNAME=""
CURRENT_TIMEZONE=$(timedatectl | awk '/Time zone:/ {print $3}')
NEW_TIMEZONE=${NEW_TIMEZONE:-}
ZONEINFO_DIR="/usr/share/zoneinfo"

# Exit when any command fails silently
set -Eeuo pipefail

# Set colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREY='\033[0;37m'

# reset color after using one of the colors above
NC='\033[0m'

# Prevents any apt prompts from breaking the script.
export DEBIAN_FRONTEND=noninteractive

# auto-confirm and faster installs
APT_FLAGS="-y -o Dpkg::Use-Pty=0"
APT_PACKAGES_NOT_INSTALLED=()

# Initialize arrays to track stop/start of autoupdate services
APT_SERVICES_AUTOUPDATE=("apt-daily.service" "apt-daily.timer" "apt-daily-upgrade.service" "apt-daily-upgrade.timer")
APT_SERVICES_AUTOUPDATE_STOPPED=()

# helper functions

save_config() {
    if [[ "${1:-}" ]]; then
        config_output_file=$1
    else
        config_output_file="provision_$(date +%F_%H%M%S).conf"
    fi
    set | grep -E "^(INSTALL_|CONFIGURE_|CREATE_|MYSQL_|PG_|POSTFIX_|MONIT_|GRAFANA_|FORGEJO_|WAZUH_|NGINX_|APPARMOR_|AUTO_|DISABLE_|LVM_RESIZE_|SWAP_|TUNE_|UNINSTALL_|UPDATE_|USER_|CURRENT_TIMEZONE)" \
        | grep -v "PASSWORD\|PASS\|SECRET|MACHINE_ARCH" \
        > $config_output_file
    echo "  Configuration parameters written to '$config_output_file'. "
}

stop_autoupdate() {
    for UNIT in "${APT_SERVICES_AUTOUPDATE[@]}"; do
        if systemctl is-active --quiet "$UNIT"; then
            echo "  Stopping $UNIT ..."
            systemctl stop --no-block "$UNIT" > /dev/null 2>&1
            # Add to tracking list
            APT_SERVICES_AUTOUPDATE_STOPPED+=("$UNIT")
        fi
    done
}

restart_autoupdate() {
    # Only loop through the ones we actually stopped
    for UNIT in "${APT_SERVICES_AUTOUPDATE_STOPPED[@]}"; do
        echo "  Restarting $UNIT ..."
        systemctl start --no-block "$UNIT" > /dev/null 2>&1
    done

    # Clear the list after restarting
    APT_SERVICES_AUTOUPDATE_STOPPED=()
}

on_error() {
    local exit_code=$?
    local line="$1"
    set +e
    trap - ERR EXIT

    # restart autoupdate services if stopped
    restart_autoupdate

    if [[ $exit_code -ne 0 ]]; then
        config_debug_file="provision_debug.conf"
        echo ""
        echo "  [!] Error: Script failed at line $line (exit code $exit_code)."
        save_config "$config_debug_file"
        echo "  Run 'sudo bash ubuntu_provision.sh $config_debug_file' if you want to continue with these settings."
        echo ""
    fi
    exit $exit_code
}

on_ctrl_c() {
    echo ""

    # restart autoupdate services if stopped
    restart_autoupdate

    if [[ "${USER_SUDO_USER_USERNAME:-}" ]]; then
        config_debug_file="provision_aborted.conf"
        echo ""
        echo "  [!] Aborting."
        save_config "$config_debug_file"
        echo "  Run 'sudo bash ubuntu_provision.sh $config_debug_file' if you want to continue with these settings."
        echo ""
    fi
    exit 0
}

check_service_installed() {
    local service="$1"
    local var="$2"
    local installed_var="${3:-}"
    local units

    # capturing to a variable with || true then grepping the variable is the safe approach whenever you need to check
    # output from a command that might legitimately return non-zero while using 'set -e'
    units=$(systemctl list-unit-files "${service}.service" 2>/dev/null) || true
    if echo "$units" | grep -q "${service}.service"; then
        echo "- $service is installed"
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

apt_install() {
    local max_attempts=3
    local attempt=1
    local wait_between_attempts=10
    while (( attempt <= max_attempts )); do
        if apt-get install $APT_FLAGS "$@" 2>&1; then
            return 0
        fi
        echo "  [!] Install attempt $attempt of $max_attempts failed for: $*"
        (( attempt++ ))
        if (( attempt <= max_attempts )); then
            echo "  Retrying in 10 seconds..."
            sleep $wait_between_attempts
        fi
    done
    echo "  [!] Warning: failed to install package(s) after $max_attempts attempts: $*"
    echo "  [!] Continuing — some functionality may be missing"
    APT_PACKAGES_NOT_INSTALLED+=("$@")
    return 1
}


prompt_if_unset() {
    local varname="$1"
    local prompt="$2"
    local silent="${3:-n}"
    local default="${4:-}"

    # echo "  prompt_if_unset(): varname='$varname', value='${!varname-}', prompt='$prompt', silent='$silent', default='$default'"
    if [[ -z "${!varname-}" ]]; then
        if [[ "$silent" == "secret" ]]; then
            while true; do
                read -rsp "$prompt : " "$varname"; echo ""
                [[ -n "${!varname}" ]] && break
                echo "  Value cannot be empty."
            done
        else
            if [[ -n "$default" ]]; then
                read -rp "$prompt [$default]: " "$varname"
                if [[ -z "${!varname}" ]]; then
                    printf -v "$varname" '%s' "$default"
                fi
            else
                while true; do
                    read -rp "$prompt : " "$varname"
                    [[ -n "${!varname}" ]] && break
                    echo "  Value cannot be empty."
                done
            fi
        fi
    else
        if [[ "$silent" == "secret" ]]; then
            echo "$prompt : ********"
        else
            echo "$prompt : ${!varname}"
        fi
    fi
}

mysql_root() {
    local defaults_file=$(mktemp)
    chmod 600 "$defaults_file"
    echo -e "[client]\npassword=$MYSQL_PASSWORD" > "$defaults_file"
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

# Write config on error and abort
trap 'on_error $LINENO' ERR
trap on_ctrl_c SIGINT

# LOGGING SETUP
LOG_FILE="/var/log/ubuntu_provision_${LOCAL_HOSTNAME}_$(date +%F_%H%M%S).log"
# Use 'exec' to redirect STDOUT and STDERR through 'tee'
# This captures EVERYTHING that follows into the log file.
exec > >(tee -a "$LOG_FILE") 2>&1


## Main
## --------------------------------------------

echo "Xlvisuals Ubuntu LTS server provisioning"
echo "Provisioning started: $(date)"
echo "Logging to: $LOG_FILE"

# Detect network IP, just for logging
echo "--- 1. Detecting network parameters  ---"

# Detect network interface
# PRIMARY_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
# PRIMARY_INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
PRIMARY_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$PRIMARY_INTERFACE" ]; then
    echo "  [!] Error: Could not detect network interface"
    exit 1
fi
echo "  Detected network interface: $PRIMARY_INTERFACE"


PRIMARY_IP=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+')
echo "  Detected network address: $PRIMARY_IP"

# Verify we have internet. Fails on Ubuntu minimized as no iputils-ping package, fall back to python
NETWORK_OK=''
if command -v ping &>/dev/null; then
    ping -c1 -W2 1.1.1.1 &>/dev/null && NETWORK_OK=y || NETWORK_OK=n
else
    python3 -c "import socket,sys; s=socket.socket(); s.settimeout(2); s.connect(('1.1.1.1',53)); s.close(); sys.exit(0)" \
        2>/dev/null && NETWORK_OK=y || NETWORK_OK=n
fi
if [[ "$NETWORK_OK" == "n" ]]; then
    echo "  [!] Error: No internet connection"
    exit 1
fi

echo ""
echo "--- 2. Configure new installation ---"

echo "  Determining installed python:"
check_file /usr/bin/python3.12 PROMPT_CPYTHON312
check_file /usr/bin/python3.13 PROMPT_CPYTHON313
check_file /usr/bin/python3.14 PROMPT_CPYTHON314
check_file /usr/local/bin/pypy3.9 PROMPT_PYPY39
check_file /usr/local/bin/pypy3.10 PROMPT_PYPY310
check_file /usr/local/bin/pypy3.11 PROMPT_PYPY311
echo "  Determining installed programs:"
check_file /usr/bin/weasyprint PROMPT_WEASYPRINT
check_file /usr/bin/convert PROMPT_IMAGEMAGICK

echo "  Determining installed services:"
check_service_installed nginx PROMPT_NGINX ISINSTALLED_NGINX
check_service_installed valkey-server PROMPT_VALKEY ISINSTALLED_VALKEY
check_service_installed mysql PROMPT_MYSQL ISINSTALLED_MYSQL
check_service_installed mariadb PROMPT_MARIADB ISINSTALLED_MARIADB
check_service_installed postgresql PROMPT_POSTGRESQL ISINSTALLED_POSTGRESQL
check_service_installed mosquitto PROMPT_MOSQUITTO ISINSTALLED_MOSQUITTO
check_service_installed postfix PROMPT_POSTFIX ISINSTALLED_POSTFIX
check_service_installed monit PROMPT_MONIT ISINSTALLED_MONIT
check_service_installed webmin PROMPT_WEBMIN ISINSTALLED_WEBMIN
check_service_installed grafana-server PROMPT_GRAFANA ISINSTALLED_GRAFANA
check_service_installed forgejo PROMPT_FORGEJO ISINSTALLED_FORGEJO
check_service_installed fail2ban PROMPT_FAIL2BAN ISINSTALLED_FAIL2BAN
check_service_installed auditd PROMPT_AUDITD ISINSTALLED_AUDITD
check_service_installed suricata PROMPT_SURICATA ISINSTALLED_SURICATA
check_service_installed wazuh-agent PROMPT_WAZUHAGENT ISINSTALLED_WAZUHAGENT
check_service_installed wazuh-manager PROMPT_WAZUHMANAGER ISINSTALLED_WAZUHMANAGER

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
        prompt_if_unset USER_USE_CURRENT_USERNAME "Use current user '$REAL_USER'? (y/n)" n "y"
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
    echo "  [!] Error: We need a sudo user to complete the setup."
    exit 1
fi

## LVM
LVM_RESIZE_VOLUME=${LVM_RESIZE_VOLUME:-}
LVM_RESIZE_TARGET_GB=${LVM_RESIZE_TARGET_GB:-}

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
            prompt_if_unset LVM_RESIZE_VOLUME "  Resize root LVM? (y/n)" n "n"
            if [[ "$LVM_RESIZE_VOLUME" =~ ^[Yy]$ ]]; then
                prompt_if_unset LVM_RESIZE_TARGET_GB "  Enter target size in GB (or type 'all')" n "all"
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
        prompt_if_unset CONFIGURE_SWAP "  Would you like to create a swap file? (y/n)" n "n"
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
        prompt_if_unset NEW_TIMEZONE "  Please enter the system timezone" n "${CURRENT_TIMEZONE}"
        if [ -n "$NEW_TIMEZONE" ] && [ -f "$ZONEINFO_DIR/$NEW_TIMEZONE" ]; then
            break
        fi
        NEW_TIMEZONE=''
        echo "  Invalid timezone. Please try again."
    done

    while true; do
        prompt_if_unset AUTO_UPDATE_DAILY_HOUR "  Hour to run apt-get update (0-23)" n "10"
        if [[ "$AUTO_UPDATE_DAILY_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
            break
        fi
        AUTO_UPDATE_DAILY_HOUR=''
        echo "  Invalid hour. Please enter a number between 0 and 23."
    done
    # apt-daily (fetch) runs twice daily, 12 hours apart
    AUTO_UPDATE_DAILY_HOUR_2=$(( (AUTO_UPDATE_DAILY_HOUR + 12) % 24 ))
    while true; do
        prompt_if_unset AUTO_UPGRADE_DAILY_HOUR "  Hour to run apt-get upgrade (0-23)" n "$(( (AUTO_UPDATE_DAILY_HOUR + 1) % 24 ))"
        if [[ "$AUTO_UPGRADE_DAILY_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
            break
        fi
        AUTO_UPGRADE_DAILY_HOUR=''
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
    prompt_if_unset INSTALL_MS_FONTS "   Install Microsoft core fonts? (y/n)" n "n"
fi

[[ "$PROMPT_WEASYPRINT" == "install" ]] && default_val="y" || default_val="n"
prompt_if_unset INSTALL_WEASYPRINT "Would you like to $PROMPT_WEASYPRINT weasyprint? (y/n)" n $default_val

[[ "$PROMPT_IMAGEMAGICK" == "install" ]] && default_val="y" || default_val="n"
prompt_if_unset INSTALL_IMAGEMAGICK "Would you like to $PROMPT_IMAGEMAGICK imagemagick? (y/n)" n $default_val

#[[ "$PROMPT_CPYTHON314" == "install" ]] && default_val="y" || default_val="n"
default_val="n"
prompt_if_unset INSTALL_CPYTHON314 "Would you like to $PROMPT_CPYTHON314 Python 3.14? (y/n)" n $default_val
if [[ ! "$INSTALL_CPYTHON314" =~ ^[Yy]$ && $PROMPT_CPYTHON314 == "reinstall" ]]; then
    # Python installed and choice is do not reinstall python. Check if important packages are installed.
    PYTHON_PACKAGES=("python3.14-venv" "pipx")
    PYTHON_PACKAGES_TO_INSTALL=()

    for PKG in "${PYTHON_PACKAGES[@]}"; do
        # -W (show) -f (format) checks if the package is installed
        if ! dpkg-query -W -f='${Status}' "$PKG" 2>/dev/null | grep -q "install ok installed"; then
            echo "  Package $PKG is missing."
            PYTHON_PACKAGES_TO_INSTALL+=("$PKG")
        fi
    done

    if [ ${#PYTHON_PACKAGES_TO_INSTALL[@]} -ne 0 ]; then
        INSTALL_CPYTHON314=""
        prompt_if_unset INSTALL_CPYTHON314 "  Would you like to $PROMPT_CPYTHON314 Python 3.14? (y/n)" n $default_val
    fi
fi


default_val="n"
prompt_if_unset INSTALL_PYPY311 "Would you like to $PROMPT_PYPY311 Pypy 3.11? (y/n)" n $default_val

#[[ "$PROMPT_NGINX" == "install" ]] && default_val="y" || default_val="n"
default_val="n"
prompt_if_unset INSTALL_NGINX "Would you like to $PROMPT_NGINX nginx? (y/n)" n $default_val
if [[ "$INSTALL_NGINX" =~ ^[Yy]$ ]]; then
  prompt_if_unset NGINX_WORKER_PROCESSES "  nginx worker processes?" n "$PROCESSOR_COUNT"
fi

#[[ "$PROMPT_VALKEY" == "install" ]] && default_val="y" || default_val="n"
default_val="n"
prompt_if_unset INSTALL_VALKEY "Would you like to $PROMPT_VALKEY valkey? (y/n)" n $default_val

#if [[ "$ISINSTALLED_MYSQL" == "y" || "$ISINSTALLED_MARIADB" == "y" || "$ISINSTALLED_POSTGRESQL" == "y" ]]; then
#    default_val='n'
#else
#    default_val='y'
#fi
default_val="n"
prompt_if_unset INSTALL_MYSQL "Would you like to $PROMPT_MYSQL MySQL? (y/n)" n $default_val
if [[ "$INSTALL_MYSQL" =~ ^[Yy]$ ]]; then
    # Installing both MySQL and MariaDB is not supported. Disabling MariaDB
    INSTALL_MARIADB=n

    # Interactive Password Prompt
    while true; do
        prompt_if_unset MYSQL_PASSWORD         "  MySQL root password" secret
        if [ "${#MYSQL_PASSWORD}" -ge 4 ]; then
            break
        fi
        MYSQL_PASSWORD=''
        echo "  Password is too short. Must be at least 4 characters."

#        prompt_if_unset MYSQL_PASSWORD_CONFIRM "  MySQL root password (confirm)" secret
#        if [ "$MYSQL_PASSWORD" == "$MYSQL_PASSWORD_CONFIRM" ] && [ "${#MYSQL_PASSWORD}" -ge 4 ]; then
#            break
#        elif [ "${#MYSQL_PASSWORD}" -lt 4 ]; then
#            MYSQL_PASSWORD=''
#            MYSQL_PASSWORD_CONFIRM=''
#            echo "  Password is too short. Must be at least 4 characters."
#        else
#            MYSQL_PASSWORD=''
#            MYSQL_PASSWORD_CONFIRM=''
#            echo "  Passwords do not match. Please try again."
#        fi
    done
    # Escape for SQL, including ' " \ $
    MYSQL_PASSWORD_ESCAPED=$(printf "%s" "$MYSQL_PASSWORD" | sed "s/'/''/g")

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
fi

#if [[ "$ISINSTALLED_MYSQL" == "y" || "$ISINSTALLED_MARIADB" == "y" || "$ISINSTALLED_POSTGRESQL" == "y" ]]; then
#    default_val='n'
#else
#    default_val='y'
#fi
default_val="n"
prompt_if_unset INSTALL_MARIADB "Would you like to $PROMPT_MARIADB MariaDB? (y/n)" n  $default_val
if [[ "$INSTALL_MARIADB" =~ ^[Yy]$ ]]; then
    if [[ "$INSTALL_MYSQL" =~ ^[Yy]$ ]]; then
        echo "  Warning: Installing both MySQL and MariaDB is not supported. Skipping MariaDB."
        INSTALL_MARIADB=n
    else
        # Reuse MYSQL_ variables — MariaDB uses identical tuning parameters
        while true; do
            prompt_if_unset MYSQL_PASSWORD "  MariaDB root password" secret
            if [ "${#MYSQL_PASSWORD}" -ge 4 ]; then
                break
            fi
            MYSQL_PASSWORD=''
            echo "  Password is too short. Must be at least 4 characters."
        done
        MYSQL_PASSWORD_ESCAPED=$(printf "%s" "$MYSQL_PASSWORD" | sed "s/'/''/g")

        prompt_if_unset MYSQL_BUFFER_POOL_CHUNK_MB "  InnoDB buffer pool chunk size (MB)" n "128"
        MYSQL_BUFFER_POOL_MB="${MYSQL_BUFFER_POOL_MB:-}"
        if [[ -z "$MYSQL_BUFFER_POOL_MB" ]]; then
            TOTAL_MEM_MB=$(free -m | awk '/^Mem:/ {print $2}')
            BUFFER_POOL_MB=$(( TOTAL_MEM_MB * 30 / 100 ))
            BUFFER_POOL_MB=$(( (BUFFER_POOL_MB / MYSQL_BUFFER_POOL_CHUNK_MB) * MYSQL_BUFFER_POOL_CHUNK_MB ))
            if (( BUFFER_POOL_MB < MYSQL_BUFFER_POOL_CHUNK_MB )); then
                BUFFER_POOL_MB=$MYSQL_BUFFER_POOL_CHUNK_MB
            fi
            echo "  Available memory: ${TOTAL_MEM_MB}MB — suggested buffer pool: ${BUFFER_POOL_MB}MB"
            prompt_if_unset MYSQL_BUFFER_POOL_MB "  InnoDB buffer pool size (MB)" n "$BUFFER_POOL_MB"
        fi
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
    fi
fi


#if [[ "$ISINSTALLED_MYSQL" == "y" || "$ISINSTALLED_MARIADB" == "y" || "$ISINSTALLED_POSTGRESQL" == "y" ]]; then
#    default_val='n'
#else
#    default_val='y'
#fi
default_val="n"
prompt_if_unset INSTALL_POSTGRESQL "Would you like to $PROMPT_POSTGRESQL PostgreSQL $PG_VERSION? (y/n)" n  $default_val
if [[ "$INSTALL_POSTGRESQL" =~ ^[Yy]$ ]]; then
    # Interactive password prompt with 4-character minimum
    while true; do
        prompt_if_unset PG_PASSWORD "  PostgreSQL superuser (postgres) password" secret
        if [ "${#PG_PASSWORD}" -ge 4 ]; then
            break
        fi
        PG_PASSWORD=''
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
    PG_PASSWORD=''
    PG_PASSWORD_ESCAPED=''
fi

#[[ "$PROMPT_MOSQUITTO" == "install" ]] && default_val="y" || default_val="n"
default_val="n"
prompt_if_unset INSTALL_MOSQUITTO "Would you like to $PROMPT_MOSQUITTO Mosquitto? (y/n)" n  $default_val

# POSTFIX
if [[ "$ISINSTALLED_POSTFIX" == "y" && -f /etc/postfix/main.cf ]]; then
    # Read existing Postfix config as defaults and so downstream prompts (Monit, Grafana, Forgejo)
    # can use POSTFIX_DOMAIN and POSTFIX_FROM_ADDRESS for their default From addresses
    TEMP_POSTFIX_DOMAIN="${POSTFIX_DOMAIN:-$(cat /etc/mailname 2>/dev/null || true)}"
    TEMP_POSTFIX_FROM_ADDRESS="${POSTFIX_FROM_ADDRESS:-$(awk '{print $2}' /etc/postfix/sender_canonical_maps 2>/dev/null | head -1 || true)}"
    TEMP_POSTFIX_ROOT_ALIAS="${POSTFIX_ROOT_ALIAS:-$(grep -oP '^root:\s*\K.*' /etc/aliases 2>/dev/null | head -1 | xargs || true)}"
    TEMP_POSTFIX_RELAY_HOST="${POSTFIX_RELAY_HOST:-$(postconf -h relayhost 2>/dev/null | grep -oP '(?<=\[)[^\]]+' || true)}"
    TEMP_POSTFIX_RELAY_PORT="${POSTFIX_RELAY_PORT:-$(postconf -h relayhost 2>/dev/null | grep -oP '(?<=:)\d+' || true)}"
    TEMP_POSTFIX_RELAY_USERNAME=""
    echo "Existing postfix configuration loaded"
else
    TEMP_POSTFIX_RELAY_HOST=''
    TEMP_POSTFIX_RELAY_PORT='587'
    TEMP_POSTFIX_RELAY_USERNAME=''
    TEMP_POSTFIX_RELAY_PASSWORD=''
    TEMP_POSTFIX_DOMAIN=''
    TEMP_POSTFIX_FROM_ADDRESS=''
    TEMP_POSTFIX_ROOT_ALIAS=''
fi

#[[ "$PROMPT_POSTFIX" == "install" ]] && default_val="y" || default_val="n"
default_val="n"
prompt_if_unset INSTALL_POSTFIX "Would you like to $PROMPT_POSTFIX Postfix (relay-only SMTP)? (y/n)" n  $default_val
if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ ]]; then
    prompt_if_unset POSTFIX_RELAY_HOST      "  SMTP relay host (mailserver address)"     n $TEMP_POSTFIX_RELAY_HOST
    prompt_if_unset POSTFIX_RELAY_PORT      "  SMTP relay port"                          n $TEMP_POSTFIX_RELAY_PORT
    prompt_if_unset POSTFIX_RELAY_USERNAME  "  SMTP relay username"                      n $TEMP_POSTFIX_RELAY_USERNAME
    while true; do
        prompt_if_unset POSTFIX_RELAY_PASSWORD "  SMTP relay password"                   secret
        if [ "${#POSTFIX_RELAY_PASSWORD}" -ge 4 ]; then
            break
        fi
        POSTFIX_RELAY_PASSWORD=''
        echo "  Password is too short. Must be at least 4 characters."
    done

    if [[ -n "$TEMP_POSTFIX_DOMAIN" ]]; then
        TEMP_POSTFIX_DOMAIN="${POSTFIX_RELAY_USERNAME#*@}"
    fi
    prompt_if_unset POSTFIX_DOMAIN          "  Mail domain (used in From address)"       n $TEMP_POSTFIX_DOMAIN

    if [[ -n "$TEMP_POSTFIX_FROM_ADDRESS" ]] then
        if [[ -n "$TEMP_POSTFIX_DOMAIN" ]]; then
            TEMP_POSTFIX_FROM_ADDRESS="$POSTFIX_RELAY_USERNAME"
        else
            TEMP_POSTFIX_FROM_ADDRESS="root@${POSTFIX_DOMAIN}"
        fi
    fi
    prompt_if_unset POSTFIX_FROM_ADDRESS    "  From address (e.g. root@domain.com)"      n $TEMP_POSTFIX_FROM_ADDRESS
    prompt_if_unset POSTFIX_ROOT_ALIAS      "  Forward local root mail to (root alias)"  n $POSTFIX_FROM_ADDRESS
else
    POSTFIX_RELAY_HOST="$TEMP_POSTFIX_RELAY_HOST"
    POSTFIX_RELAY_PORT="$TEMP_POSTFIX_RELAY_PORT"
    POSTFIX_RELAY_USERNAME="$TEMP_POSTFIX_RELAY_USERNAME"
    POSTFIX_RELAY_PASSWORD=''
    POSTFIX_DOMAIN="$TEMP_POSTFIX_DOMAIN"
    POSTFIX_FROM_ADDRESS="$TEMP_POSTFIX_FROM_ADDRESS"
    POSTFIX_ROOT_ALIAS="$TEMP_POSTFIX_FROM_ADDRESS"
fi

#[[ "$PROMPT_MONIT" == "install" ]] && default_val="y" || default_val="n"
default_val="n"
prompt_if_unset INSTALL_MONIT "Would you like to $PROMPT_MONIT Monit? (y/n)" n  $default_val
if [[ "$INSTALL_MONIT" =~ ^[Yy]$ ]]; then
    # allow conf file to override, fall back to hostname, never prompt
    MONIT_HOST_NAME="${MONIT_HOST_NAME:-$LOCAL_HOSTNAME}"

    if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ || "$ISINSTALLED_POSTFIX" == "y" ]]; then
        prompt_if_unset MONIT_USE_POSTFIX "  Send Monit alerts via Postfix? (y/n)" n "n"
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
    POSTFIX_ROOT_ALIAS="${POSTFIX_ROOT_ALIAS:-}"
    prompt_if_unset MONIT_ALERT_RECIPIENT     "  Alert recipient address" n $POSTFIX_ROOT_ALIAS
fi

prompt_if_unset INSTALL_WEBMIN "Would you like to $PROMPT_WEBMIN Webmin? (y/n)" n "n"

#[[ "$PROMPT_GRAFANA" == "install" ]] && default_val="y" || default_val="n"
default_val="n"
prompt_if_unset INSTALL_GRAFANA "Would you like to $PROMPT_GRAFANA Grafana? (y/n)" n  $default_val
if [[ "$INSTALL_GRAFANA" =~ ^[Yy]$ ]]; then
    if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ || "$ISINSTALLED_POSTFIX" == "y" ]]; then
        prompt_if_unset GRAFANA_USE_POSTFIX "  Send Grafana alerts via Postfix? (y/n)" n "n"
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

#[[ "$PROMPT_FORGEJO" == "install" ]] && default_val="y" || default_val="n"
default_val="n"
prompt_if_unset INSTALL_FORGEJO "Would you like to $PROMPT_FORGEJO Forgejo? (y/n)" n  $default_val
if [[ "$INSTALL_FORGEJO" =~ ^[Yy]$ ]]; then
    if [[ "$INSTALL_GRAFANA" =~ ^[Yy]$ || "$ISINSTALLED_GRAFANA" == "y" ]]; then
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

    if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ || "$ISINSTALLED_POSTFIX" == "y" ]]; then
        prompt_if_unset FORGEJO_USE_POSTFIX "  Send Forgejo mail via Postfix? (y/n)" n "n"
    else
        FORGEJO_USE_POSTFIX="n"
    fi

    if [[ "$FORGEJO_USE_POSTFIX" =~ ^[Yy]$ ]]; then
        FORGEJO_MAILER_ENABLED="true"
        FORGEJO_SMTP_PROTOCOL="smtp"
        FORGEJO_SMTP_ADDR="localhost"
        FORGEJO_SMTP_PORT="25"
        FORGEJO_SMTP_USER=""
        FORGEJO_SMTP_PASSWORD=""
        prompt_if_unset FORGEJO_SMTP_FROM "  From address"  n "forgejo@${POSTFIX_DOMAIN}"
    else
        prompt_if_unset FORGEJO_MAILER_ENABLED  "  Enable mailer? (true/false)"  n "true"
        if [[ "$FORGEJO_MAILER_ENABLED" == "true" ]]; then
            prompt_if_unset FORGEJO_SMTP_ADDR   "  SMTP host"                   n
            prompt_if_unset FORGEJO_SMTP_PORT   "  SMTP port"                   n "587"
            prompt_if_unset FORGEJO_SMTP_PROTOCOL   "  SMTP protocol"           n "smtps"
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

    # Database configuration
    prompt_if_unset FORGEJO_DB_TYPE "  Forgejo database type (sqlite3/mysql/postgres)" n "sqlite3"
    if [[ "$FORGEJO_DB_TYPE" != "sqlite3" ]]; then
        prompt_if_unset FORGEJO_DB_NAME "  Forgejo database name" n "forgejo"
        prompt_if_unset FORGEJO_DB_USER "  Forgejo database user" n "forgejo"
        while true; do
            prompt_if_unset FORGEJO_DB_PASSWORD "  Forgejo database password" secret
            if [ "${#FORGEJO_DB_PASSWORD}" -ge 4 ]; then
                break
            fi
            FORGEJO_DB_PASSWORD=''
            echo "  Password is too short. Must be at least 4 characters."
        done
        if [[ "$FORGEJO_DB_TYPE" == "mysql" ]]; then
            FORGEJO_DB_HOST="127.0.0.1:3306"
        elif [[ "$FORGEJO_DB_TYPE" == "postgres" ]]; then
            FORGEJO_DB_HOST="127.0.0.1:5432"
        fi
    else
        FORGEJO_DB_NAME=""
        FORGEJO_DB_USER=""
        FORGEJO_DB_PASSWORD=""
        FORGEJO_DB_HOST=""
    fi

    # Admin user configuration
    while true; do
        prompt_if_unset FORGEJO_ADMIN_USERNAME "  Forgejo admin username" n "$(hostname -s)"
        if [[ "$FORGEJO_ADMIN_USERNAME" == "admin" ]]; then
            echo "  'admin' is reserved by Forgejo. Please choose a different username."
            FORGEJO_ADMIN_USERNAME=""
        else
            break
        fi
    done
    while true; do
        prompt_if_unset FORGEJO_ADMIN_PASSWORD "  Forgejo admin password" secret
        if [ "${#FORGEJO_ADMIN_PASSWORD}" -ge 4 ]; then
            break
        fi
        FORGEJO_ADMIN_PASSWORD=''
        echo "  Password is too short. Must be at least 4 characters."
    done
    FORGEJO_SMTP_FROM="${FORGEJO_SMTP_FROM:-forgejo@${POSTFIX_DOMAIN:-}}"
    prompt_if_unset FORGEJO_ADMIN_EMAIL "  Forgejo admin email" n $FORGEJO_SMTP_FROM
fi
prompt_if_unset DISABLE_TX_OFFLOAD "Would you like to disable TCP transmit offloading? (y/n)" n "n"

#[[ "$PROMPT_FAIL2BAN" == "install" ]] && default_val="y" || default_val="n"
default_val="n"
prompt_if_unset INSTALL_FAIL2BAN "Would you like to $PROMPT_FAIL2BAN Fail2Ban? (y/n)" n  $default_val

#[[ "$PROMPT_AUDITD" == "install" ]] && default_val="y" || default_val="n"
default_val="n"
prompt_if_unset INSTALL_AUDITD "Would you like to $PROMPT_AUDITD auditd? (y/n)" n  $default_val

#[[ "$PROMPT_IPBLOCK" == "install" ]] && default_val="y" || default_val="n"
default_val="n"
prompt_if_unset INSTALL_IPBLOCK "Would you like to $PROMPT_IPBLOCK IP blocklist? (y/n)" n  $default_val

#[[ "$PROMPT_SURICATA" == "install" ]] && default_val="y" || default_val="n"
default_val="n"
prompt_if_unset INSTALL_SURICATA "Would you like to $PROMPT_SURICATA Suricata IDS? (y/n)" n  $default_val

#if [[ "$ISINSTALLED_WAZUHAGENT" == "y" ]]; then
#    default_val='n'
#else
#    default_val='y'
#fi
default_val='n'
prompt_if_unset INSTALL_WAZUHAGENT "Would you like to $PROMPT_WAZUHAGENT Wazuh Agent? (y/n)" n  $default_val
if [[ "$INSTALL_WAZUHAGENT" =~ ^[Yy]$ ]]; then
    # Interactive Manager host prompt
    while true; do
        #read -p "  Enter IP or Hostname of Wazuh Manager : " WAZUH_MANAGER
        prompt_if_unset WAZUH_MANAGER "  Enter IP or Hostname of Wazuh Manager" n
        if [[ ${#WAZUH_MANAGER} -ge 4 ]]; then
            break
        fi
    done
else
    WAZUH_MANAGER=''
fi

prompt_if_unset CONFIGURE_APPARMOR "Would you like to configure AppArmor? (y/n)" n "n"
if [[ "$CONFIGURE_APPARMOR" =~ ^[Yy]$ ]]; then
    echo "  AppArmor status: installed=$APPARMOR_INSTALLED, enabled=$APPARMOR_ENABLED, mode=$APPARMOR_CURRENT_MODE"
    prompt_if_unset APPARMOR_ENABLE "  Enable AppArmor? (y/n)" n "n"
    prompt_if_unset APPARMOR_ENFORCE "  Set profiles to enforce mode? (y/n)" n "$( [[ "$APPARMOR_CURRENT_MODE" == "enforce" ]] && echo y || echo n )"
fi

prompt_if_unset CONFIGURE_MODULEJAIL "Blacklist unused kernel modules using modulejail? (y/n)" n "n"

# Detect current Ubuntu Pro attachment status for use in the prompt
echo "Detecting current Ubuntu Pro attachment status ..."
UBUNTU_PRO_ATTACHED="n"
if pro status --format json 2>/dev/null | grep -q '"attached": true'; then
    UBUNTU_PRO_ATTACHED="y"
fi

if [[ "$UBUNTU_PRO_ATTACHED" == "y" ]]; then
    echo "  Ubuntu Pro: already attached — no token needed"
    CONFIGURE_UBUNTU_PRO="y"
    UBUNTU_PRO_TOKEN=""
else
    prompt_if_unset CONFIGURE_UBUNTU_PRO "Would you like to attach Ubuntu Pro? (y/n)" n "n"
    if [[ "$CONFIGURE_UBUNTU_PRO" =~ ^[Yy]$ ]]; then
        prompt_if_unset UBUNTU_PRO_TOKEN "  Ubuntu Pro token" secret
    fi
fi

prompt_if_unset CONFIGURE_CIS_HARDENING "Would you like to apply CIS Level 1 hardening? (y/n)" n "n"

prompt_if_unset CREATE_HEALTHSCRIPT "Would you like to create and run the Health Check script? (y/n)" n "y"

echo "Configuration complete."


SSH_HARDENED_CONF="/etc/ssh/sshd_config.d/01-$USER_SUDO_USER_USERNAME-hardened.conf"

## Print Configuration
## --------------------------------------------
echo ""
echo ""
echo "-- Configuration settings --"
echo "Add sudo user?               : $USER_CREATE_SUDO_USER"
if [[ "$USER_CREATE_SUDO_USER" =~ ^[Yy]$ ]]; then
  echo "  new username               : $USER_SUDO_USER_USERNAME"
else
  echo "  existing username          : $USER_SUDO_USER_USERNAME"
fi
echo "Configure LVM disks?         : $CONFIGURE_LVM"
if [[ "$CONFIGURE_LVM" =~ ^[Yy]$ ]]; then
  echo "  Resize LVM?                : ${LVM_RESIZE_VOLUME:-n}"
  if [[ "$LVM_RESIZE_VOLUME" =~ ^[Yy]$ ]]; then
    echo "  LVM target GB              : ${LVM_RESIZE_TARGET_GB:-all}"
  fi
fi
echo "Configure swap space?        : $CONFIGURE_SWAP"
if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ && "$ACTIVE_SWAP" == "No" ]]; then
  echo "  Swap size (GB)             : ${SWAP_SIZE_GB:-2}"
fi
echo "Tune system?                 : $TUNE_SYSTEM"
if [[ "$TUNE_SYSTEM" =~ ^[Yy]$ ]]; then
  echo "  Current timezone           : $CURRENT_TIMEZONE"
  if [[ -n "$NEW_TIMEZONE" && "$NEW_TIMEZONE" != "$CURRENT_TIMEZONE" ]]; then
      echo "  New timezone               : $NEW_TIMEZONE"
  fi
  echo "  apt update hour            : $AUTO_UPDATE_DAILY_HOUR and $AUTO_UPDATE_DAILY_HOUR_2 (twice daily)"
  echo "  apt upgrade hour           : $AUTO_UPGRADE_DAILY_HOUR"
fi
echo "Uninstall extra packages?    : $UNINSTALL_PACKAGES"
echo "Update installed packages?   : $UPDATE_PACKAGES"
echo "Install admin packages?      : $INSTALL_PACKAGES"
echo "Install ufw?                 : $INSTALL_UFW"
echo "Install ssh?                 : $INSTALL_SSH"
echo "  SSH overwrite file         : $SSH_HARDENED_CONF"
echo "Install fonts?               : $INSTALL_FONTS"
if [[ "$INSTALL_FONTS" =~ ^[Yy]$ ]]; then
  echo "  Install MS core fonts?     : $INSTALL_MS_FONTS"
fi
echo "Install weasyprint?          : $INSTALL_WEASYPRINT"
echo "Install imagemagick?         : $INSTALL_IMAGEMAGICK"
echo "Install Python 3.14?         : $INSTALL_CPYTHON314"
echo "Install Pypy 3.11?           : $INSTALL_PYPY311"
echo "Install nginx?               : $INSTALL_NGINX"
if [[ "$INSTALL_NGINX" =~ ^[Yy]$ ]]; then
  echo "    nginx worker processes   : $NGINX_WORKER_PROCESSES"
fi
echo "Install valkey?              : $INSTALL_VALKEY"
echo "Install MySQL?               : $INSTALL_MYSQL"
if [[ "$INSTALL_MYSQL" =~ ^[Yy]$ ]]; then
  echo "  Buffer pool chunk MB       : $MYSQL_BUFFER_POOL_CHUNK_MB"
  echo "  Buffer pool MB             : $MYSQL_BUFFER_POOL_MB"
  echo "  Buffer pool instances      : $MYSQL_BUFFER_POOL_INSTANCES"
  echo "  Max connections            : $MYSQL_MAX_CONNECTIONS"
  echo "  Log buffer MB              : $MYSQL_LOG_BUFFER_MB"
  echo "  Binlog cache MB            : $MYSQL_BINLOG_CACHE_MB"
  echo "  Join buffer KB             : $MYSQL_JOIN_BUFFER_KB"
  echo "  Sort buffer KB             : $MYSQL_SORT_BUFFER_KB"
  echo "  Read buffer KB             : $MYSQL_READ_BUFFER_KB"
  echo "  Read rnd buffer KB         : $MYSQL_READ_RND_BUFFER_KB"
fi
echo "Install MariaDB?             : $INSTALL_MARIADB"
if [[ "$INSTALL_MARIADB" =~ ^[Yy]$ ]]; then
  echo "  Buffer pool chunk MB       : $MYSQL_BUFFER_POOL_CHUNK_MB"
  echo "  Buffer pool MB             : $MYSQL_BUFFER_POOL_MB"
  echo "  Buffer pool instances      : $MYSQL_BUFFER_POOL_INSTANCES"
  echo "  Max connections            : $MYSQL_MAX_CONNECTIONS"
  echo "  Log buffer MB              : $MYSQL_LOG_BUFFER_MB"
  echo "  Binlog cache MB            : $MYSQL_BINLOG_CACHE_MB"
  echo "  Join buffer KB             : $MYSQL_JOIN_BUFFER_KB"
  echo "  Sort buffer KB             : $MYSQL_SORT_BUFFER_KB"
  echo "  Read buffer KB             : $MYSQL_READ_BUFFER_KB"
  echo "  Read rnd buffer KB         : $MYSQL_READ_RND_BUFFER_KB"
fi
echo "Install PostgreSQL?          : $INSTALL_POSTGRESQL"
if [[ "$INSTALL_POSTGRESQL" =~ ^[Yy]$ ]]; then
  echo "  Max connections            : $PG_MAX_CONNECTIONS"
  echo "  Shared buffers MB          : $PG_SHARED_BUFFERS_MB"
  echo "  Work mem MB                : $PG_WORK_MEM_MB"
  echo "  Effective cache MB         : $PG_EFFECTIVE_CACHE_MB"
  echo "  Max worker processes       : $PG_MAX_WORKER_PROCESSES"
  echo "  Max parallel workers       : $PG_MAX_PARALLEL_WORKERS"
  echo "  Max parallel w/gather      : $PG_MAX_PARALLEL_WORKERS_PG"
  echo "  Effective IO concurr.      : $PG_EFFECTIVE_IO_CONCURRENCY"
  echo "  Superuser password         : ********"
fi
echo "Install Mosquitto?           : $INSTALL_MOSQUITTO"
echo "Install Postfix?             : $INSTALL_POSTFIX"
if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ ]]; then
  echo "  Relay host                 : $POSTFIX_RELAY_HOST:$POSTFIX_RELAY_PORT"
  echo "  Relay username             : $POSTFIX_RELAY_USERNAME"
  echo "  Relay password             : ********"
  echo "  Mail domain                : $POSTFIX_DOMAIN"
  echo "  From address               : $POSTFIX_FROM_ADDRESS"
  echo "  Root alias                 : $POSTFIX_ROOT_ALIAS"
fi
echo "Install Monit?               : $INSTALL_MONIT"
if [[ "$INSTALL_MONIT" =~ ^[Yy]$ ]]; then
  echo "  Monit host name            : $MONIT_HOST_NAME"
  if [[ "$MONIT_USE_POSTFIX" =~ ^[Yy]$ ]]; then
    echo "  Mail via               : Postfix (localhost:25)"
  else
    echo "  Mail server host         : $MONIT_MAILSERVER_HOST"
    echo "  Mail server port         : $MONIT_MAILSERVER_PORT"
    echo "  Mail server username     : $MONIT_MAILSERVER_USERNAME"
    echo "  Mail server password     : ********"
  fi
  echo "  Monit admin username       : $MONIT_ADMIN_USERNAME"
  echo "  Monit admin password       : ********"
  echo "  Alert sender               : $MONIT_ALERT_SENDER"
  echo "  Alert recipient            : $MONIT_ALERT_RECIPIENT"
fi
echo "Install Webmin?              : $INSTALL_WEBMIN"
echo "Install Grafana?             : $INSTALL_GRAFANA"
if [[ "$INSTALL_GRAFANA" =~ ^[Yy]$ ]]; then
  echo "  Random secret              : ********"

  if [[ "$GRAFANA_USE_POSTFIX" =~ ^[Yy]$ ]]; then
    echo "  Mail via                 : Postfix (localhost:25)"
    echo "  From address               : $GRAFANA_SMTP_FROM_ADDRESS"
    echo "  From name                  : $GRAFANA_SMTP_FROM_NAME"
  else
    echo "  SMTP enabled             : $GRAFANA_SMTP_ENABLED"
    if [[ "$GRAFANA_SMTP_ENABLED" == "true" ]]; then
      echo "  SMTP host                : $GRAFANA_SMTP_HOST"
      echo "  SMTP port                : $GRAFANA_SMTP_PORT"
      echo "  SMTP user                : $GRAFANA_SMTP_USER"
      echo "  SMTP password            : ********"
      echo "  From address             : $GRAFANA_SMTP_FROM_ADDRESS"
      echo "  From name                : $GRAFANA_SMTP_FROM_NAME"
      echo "  EHLO identity            : $GRAFANA_SMTP_EHLO_IDENTITY"
      echo "  StartTLS policy          : $GRAFANA_SMTP_STARTTLS_POLICY"
    fi
  fi
fi
echo "Install Forgejo?             : $INSTALL_FORGEJO"
if [[ "$INSTALL_FORGEJO" =~ ^[Yy]$ ]]; then
  echo "  Forgejo domain/ip          : $FORGEJO_DOMAIN"
  echo "  Forgejo port               : $FORGEJO_PORT"
  echo "  Database type              : $FORGEJO_DB_TYPE"
  if [[ "$FORGEJO_DB_TYPE" != "sqlite3" ]]; then
    echo "  Database name              : $FORGEJO_DB_NAME"
    echo "  Database user              : $FORGEJO_DB_USER"
    echo "  Database host              : $FORGEJO_DB_HOST"
    echo "  Database password          : ********"
  fi
  echo "  Admin username             : $FORGEJO_ADMIN_USERNAME"
  echo "  Admin password             : ********"
  echo "  Admin email                : $FORGEJO_ADMIN_EMAIL"
  if [[ "$FORGEJO_USE_POSTFIX" =~ ^[Yy]$ ]]; then
    echo "  Mail via                 : Postfix (localhost:25)"
    echo "  From address               : $FORGEJO_SMTP_FROM"
  else
    echo "  Mailer enabled             : $FORGEJO_MAILER_ENABLED"
    if [[ "$FORGEJO_MAILER_ENABLED" == "true" ]]; then
      echo "  SMTP host                  : $FORGEJO_SMTP_ADDR"
      echo "  SMTP port                  : $FORGEJO_SMTP_PORT"
      echo "  SMTP protocol              : $FORGEJO_SMTP_PROTOCOL"
      echo "  From address               : $FORGEJO_SMTP_FROM"
      echo "  SMTP user                  : $FORGEJO_SMTP_USER"
      echo "  SMTP password              : ********"
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
echo "Install Wazuh Agent?         : $INSTALL_WAZUHAGENT"
if [[ "$INSTALL_WAZUHAGENT" =~ ^[Yy]$ ]]; then
  echo "  Wazuh Manager              : $WAZUH_MANAGER"
fi
echo "Configure AppArmor?          : $CONFIGURE_APPARMOR"
if [[ "$CONFIGURE_APPARMOR" =~ ^[Yy]$ ]]; then
  echo "  Enable AppArmor            : $APPARMOR_ENABLE"
  echo "  Enforce mode               : $APPARMOR_ENFORCE"
fi
echo "Configure modulejail?        : $CONFIGURE_MODULEJAIL"
echo "Attach Ubuntu Pro?           : $CONFIGURE_UBUNTU_PRO"
if [[ "$UBUNTU_PRO_ATTACHED" == "y" ]]; then
  echo "  (already attached)"
elif [[ "$CONFIGURE_UBUNTU_PRO" =~ ^[Yy]$ ]]; then
  echo "  Token                      : [provided]"
fi
echo "Apply CIS Level 1 hardening? : $CONFIGURE_CIS_HARDENING"
echo "Create and run Health Check? : $CREATE_HEALTHSCRIPT"
echo ""
save_config

echo ""

if [[ "${FORCE_APPLY:-}" =~ ^[Yy]$ ]]; then
    echo "Proceed with installation confirmed by FORCE_APPLY variable."
else
    while true; do
        read -rp "Configuration printed above. Proceed with installation? (y/n) " CONFIRM_APPLY

        case "$CONFIRM_APPLY" in
            [Yy]*)
                # If yes, break the loop and continue the script
                break
                ;;
            [Nn]*)
                echo "Aborted by user."
                exit 0
                ;;
            *)
                echo "Invalid input. Please enter 'y' for yes or 'n' for no."
                ;;
        esac
    done
fi

echo ""
echo "--- 3. Preparation ---"

ANY_INSTALL_SET=
if set | grep -qE "^INSTALL_[A-Z_]+=y$"; then
    ANY_INSTALL_SET=y
fi
ANY_CONFIGURE_SET=
if set | grep -qE "^CONFIGURE_[A-Z_]+=y$"; then
    ANY_CONFIGURE_SET=y
fi
ANY_INSTALL_OR_CONFIGURE_SET=
if set | grep -qE "^(INSTALL_|CONFIGURE_)[A-Z_]+=y$"; then
    ANY_INSTALL_OR_CONFIGURE_SET=y
fi

if [[ "$ANY_INSTALL_SET" =~ ^[Yy]$ ]]; then
    echo ""
    echo "--- Stopping unattended upgrades ---"
    stop_autoupdate
fi

if [[ "$ANY_INSTALL_OR_CONFIGURE_SET" =~ ^[Yy]$ ]]; then
    echo "--- Backup current configuration ---"
    BACKUP_SCRIPT="$(dirname "$(readlink -f "$0")")/ubuntu_backup_config.sh"
    if [[ -f "$BACKUP_SCRIPT" ]]; then
        bash "$BACKUP_SCRIPT" "${LOCAL_HOSTNAME}_pre-apply"
        echo "  Pre-apply configuration backup complete."
    else
        echo "  Warning: ubuntu_backup_config.sh not found alongside this script, skipping backup."
    fi
fi

## Apply settings
## --------------------------------------------

echo ""
echo "--- 4. Create/update user ---"
if [[ "$USER_CREATE_SUDO_USER" =~ ^[Yy]$ ]]; then
    if ! id "$USER_SUDO_USER_USERNAME" &>/dev/null; then
        echo "  Creating user $USER_SUDO_USER_USERNAME."
        adduser --gecos "" --disabled-password "$USER_SUDO_USER_USERNAME"
        echo "  Created user $USER_SUDO_USER_USERNAME"
        echo ""
        echo "  Setting system password for user: $USER_SUDO_USER_USERNAME"
        passwd $USER_SUDO_USER_USERNAME
        usermod -aG sudo $USER_SUDO_USER_USERNAME
        usermod -a -G adm $USER_SUDO_USER_USERNAME
        chmod 750 /home/$USER_SUDO_USER_USERNAME
    else
        echo "  User $USER_SUDO_USER_USERNAME exists."
    fi
else
    echo "  Skipping new sudo user."
fi
if [[ -n "$USER_SUDO_USER_USERNAME" ]]; then
    if ! id -nG "$USER_SUDO_USER_USERNAME" | grep -qw "sudo"; then
        echo "  Adding user $USER_SUDO_USER_USERNAME to group sudo"
        usermod -a -G sudo "$USER_SUDO_USER_USERNAME"
    fi
    if ! id -nG "$USER_SUDO_USER_USERNAME" | grep -qw "adm"; then
        echo "  Adding user $USER_SUDO_USER_USERNAME to group adm"
        usermod -a -G adm "$USER_SUDO_USER_USERNAME"
    fi
    echo "  Setting home folder permissions for user $USER_SUDO_USER_USERNAME to 750"
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
            echo "  LVM detected. Free space in Volume Group: ${LVM_FREE_GB}GB"
            prompt_if_unset LVM_RESIZE_VOLUME "Resize root LVM? (y/n)" n "n"
            if [[ "$LVM_RESIZE_VOLUME" =~ ^[Yy]$ ]]; then
                prompt_if_unset LVM_RESIZE_TARGET_GB "Enter target size in GB (or type 'all')" n "all"

                if [ "$LVM_RESIZE_TARGET_GB" == "all" ]; then
                    lvextend -l +100%FREE "$LV_PATH"
                else
                    lvextend -L "${LVM_RESIZE_TARGET_GB}G" "$LV_PATH"
                fi
                resize2fs "$LV_PATH"
            fi

        else
            echo "  LVM detected, but no free space remains in Volume Group. Skipping."
        fi
    else
        echo "  Logical Volume $LV_PATH not found (System may not use LVM). Skipping."
    fi
else
    echo "  Skipping LVM configuration."
fi


echo ""
echo "--- 6. Configure Swap Space ---"
if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ ]]; then
    # 1. Check if swap is currently active (via /proc/swaps)
    # We ignore the header line; if the output is empty, no swap is active.
    CURRENT_SWAP_ACTIVE=$(tail -n +2 /proc/swaps)

    if [ -z "$CURRENT_SWAP_ACTIVE" ]; then
        echo "  No active swap detected."
        prompt_if_unset CONFIGURE_SWAP "Would you like to create a swap file? (y/n)" n "all"

        if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ ]]; then
            # Ask for size with a sensible default
            prompt_if_unset SWAP_SIZE_GB "Enter swap size in GB" n "2"

            # Define the path (using /swapfile as per your original script)
            SWAP_PATH="/swapfile"

            if [ ! -f "$SWAP_PATH" ]; then
                echo "  Creating ${SWAP_SIZE_GB}GB swap file at $SWAP_PATH..."
                # fallocate is faster, dd is the fallback
                fallocate -l "${SWAP_SIZE_GB}G" "$SWAP_PATH" || dd if=/dev/zero of="$SWAP_PATH" bs=1M count=$((SWAP_SIZE_GB * 1024))

                chmod 600 "$SWAP_PATH"
                mkswap "$SWAP_PATH"
                swapon "$SWAP_PATH"

                # Append to fstab if not already there
                if ! grep -q "$SWAP_PATH" /etc/fstab; then
                    echo "$SWAP_PATH none swap sw 0 0" >> /etc/fstab
                fi
                echo "  Swap file created and activated."
            else
                echo "  A file exists at $SWAP_PATH but is not active. Please check manually."
            fi
        fi
    else
        echo "  Active swap detected. Skipping swap creation."
        swapon --show
    fi
else
    echo "  Skipping swap configuration."
fi


echo ""
echo "--- 7. Uninstall unneeded packages ---"
if [[ "$UNINSTALL_PACKAGES" =~ ^[Yy]$ ]]; then
    apt-get purge -y --auto-remove modemmanager udisks2 apport bluetooth bluez snapd snapd-core || true

    # Cleanup leftover config packages
    # sudo apt-get autoremove -y ; sudo apt-get -y purge $(dpkg --list | grep ^rc | awk '{ print $2; }')
    mapfile -t RC_PACKAGES < <(dpkg --list | awk '/^rc/ {print $2}')
    if [ ${#RC_PACKAGES[@]} -gt 0 ]; then
        echo "  Purging leftover configuration packages: ${RC_PACKAGES[*]}"
        apt-get purge -y "${RC_PACKAGES[@]}" || true
    else
        echo "  No leftover config packages found."
    fi
    apt-get autoremove -y || true
else
    echo "  Skipping uninstall."
fi


echo ""
echo "--- 8. Update/Upgrade system packages ---"
if [[ "$UPDATE_PACKAGES" =~ ^[Yy]$ ]]; then
    wait_for_apt
    echo "  Updating packages ..."
    apt-get update
    echo "  Upgrading packages ..."
    apt-get -y full-upgrade
elif [[ "$ANY_INSTALL_SET" =~ ^[Yy]$ ]]; then
    # update, but not ugprade
    wait_for_apt
    echo "  Updating packages ..."
    apt-get update
    echo "  Skipping upgrade ..."
else
    echo "  Skipping update and upgrade."
fi


echo ""
echo "--- 9. Install recommended tools ---"
if [[ "$INSTALL_PACKAGES" =~ ^[Yy]$ ]]; then
    wait_for_apt
    apt_install apt-file apt-show-versions apt-utils arping btop ca-certificates curl debsums dnsutils \
          git git-lfs gnupg gnupg2 gpg iftop iotop iputils-ping jq lsb-release lsof lynis mc micro mtr nano ncdu ne \
          needrestart net-tools nethogs nmap p7zip-full rsync sed socat speedtest-cli sysstat tmux traceroute tree \
          unattended-upgrades unzip vim vim-gui-common wget zip
    apt-file update

    if [[ "$(systemd-detect-virt)" == "none" ]]; then
        echo "  Bare metal detected. Installing smartmontools"
        apt_install smartmontools || true
    else
        echo "  Running in $(systemd-detect-virt). Skipping smartmontools installation."
    fi
else
    echo "  Skipping tools installation."
fi


echo ""
echo "--- 10. Install and configure ufw firewall ---"
if [[ "$INSTALL_UFW" =~ ^[Yy]$ ]]; then
    wait_for_apt
    if apt_install ufw rsyslog; then
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
        echo "  [!] Firewall installation failed — skipping configuration"
    fi
else
    echo "  Skipping ufw installation."
fi

echo ""
echo "--- 11. Install and configure OpenSSH ---"
if [[ "$INSTALL_SSH" =~ ^[Yy]$ ]]; then
    wait_for_apt
    if apt_install openssh-server; then

        # SSH Key Logic: Prompt for ssh key if none exists
        mkdir -p /home/$USER_SUDO_USER_USERNAME/.ssh
        chown $USER_SUDO_USER_USERNAME:$USER_SUDO_USER_USERNAME /home/$USER_SUDO_USER_USERNAME/.ssh
        chmod 700 /home/$USER_SUDO_USER_USERNAME/.ssh
        AUTH_KEYS="/home/$USER_SUDO_USER_USERNAME/.ssh/authorized_keys"
        if [ ! -f "$AUTH_KEYS" ] || [ ! -s "$AUTH_KEYS" ]; then
            echo "  SSH KEY SETUP"
            echo "  No existing keys found for $USER_SUDO_USER_USERNAME."
            echo "  Please paste your SSH PUBLIC KEY (starts with ssh-rsa, ssh-ed25519, etc.):"
            read -r SSH_PUBLIC_KEY
            if [ -n "$SSH_PUBLIC_KEY" ]; then
                mkdir -p /home/$USER_SUDO_USER_USERNAME/.ssh
                echo "$SSH_PUBLIC_KEY" > "$AUTH_KEYS"
                chmod 700 /home/$USER_SUDO_USER_USERNAME/.ssh
                chmod 600 "$AUTH_KEYS"
                chown -R $USER_SUDO_USER_USERNAME:$USER_SUDO_USER_USERNAME /home/$USER_SUDO_USER_USERNAME/.ssh
                echo "  SSH key installed for $USER_SUDO_USER_USERNAME."
            else
                echo "  [!] ERROR: No SSH key installed. Aborting to prevent lockout."
                exit 1
            fi
        else
            echo "  SSH keys already present in $AUTH_KEYS. Skipping prompt."
        fi

        echo "  Hardening ssh..."
        # Override file ensures custom settings take precedence in Ubuntu 26.04.
        # Using <<EOF, not <<'EOF', so that $USER_SUDO_USER_USERNAME is replaced.
        cat <<EOF > $SSH_HARDENED_CONF
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
        echo "  [!] OpenSSH installation failed — skipping configuration"
    fi
else
    echo "  Skipping OpenSSH installation."
fi


echo ""
echo "--- 12. Harden PAM: Prevent Login to Accounts With Empty Password ---"
# Remove 'nullok' from PAM config to prevent authentication with empty passwords.
# This satisfies CIS Level 1 / USG benchmark: "Prevent Login to Accounts With Empty Password" (High severity).
# Check for accounts with empty passwords first — should return nothing on a properly set up server.
EMPTY_PASSWORD_ACCOUNTS=$(awk -F: '($2 == "") {print $1}' /etc/shadow 2>/dev/null || true)
if [[ -n "$EMPTY_PASSWORD_ACCOUNTS" ]]; then
    echo "  [!] WARNING: The following accounts have empty passwords: $EMPTY_PASSWORD_ACCOUNTS"
    echo "  [!] These accounts should be reviewed and locked immediately."
    for ACCOUNT in $EMPTY_PASSWORD_ACCOUNTS; do
        passwd -l "$ACCOUNT"
        echo "  Locked account: $ACCOUNT"
    done
else
    echo "  No accounts with empty passwords found."
fi

# Remove 'nullok' from all PAM config files to enforce the policy at the PAM level
NULLOK_FILES=$(grep -rl 'nullok' /etc/pam.d/ 2>/dev/null || true)
if [[ -n "$NULLOK_FILES" ]]; then
    echo "  Removing 'nullok' from PAM configuration files:"
    for PAM_FILE in $NULLOK_FILES; do
        sed -i 's/ nullok//g' "$PAM_FILE"
        echo "  [V] Patched: $PAM_FILE"
    done
else
    echo "  'nullok' not present in any PAM config files — already hardened."
fi


if [[ "$TUNE_SYSTEM" =~ ^[Yy]$ ]]; then

    echo ""
    echo "--- 13. Localization  ---"
    if [[ -n "$NEW_TIMEZONE" && "$NEW_TIMEZONE" != "$CURRENT_TIMEZONE" ]]; then
        timedatectl set-timezone "$NEW_TIMEZONE"
        echo "  Timezone changed from $CURRENT_TIMEZONE to $NEW_TIMEZONE."
    else
        echo "  Skipping changing timezone from $CURRENT_TIMEZONE"
    fi

    echo ""
    echo "--- 14. Override sudo settings ---"
    echo "Defaults timestamp_timeout=60" > /etc/sudoers.d/$USER_SUDO_USER_USERNAME-timeout
    echo "  Adding /usr/bin/apt-get update, /usr/bin/apt-get upgrade, /usr/bin/systemctl, /home/$USER_SUDO_USER_USERNAME/ubuntu_health_check.sh to new sudoers file: /etc/sudoers.d/$USER_SUDO_USER_USERNAME-commands"
    echo "$USER_SUDO_USER_USERNAME ALL=(ALL) NOPASSWD:/usr/bin/apt-get update, /usr/bin/apt-get upgrade, /usr/bin/systemctl, /home/$USER_SUDO_USER_USERNAME/ubuntu_health_check.sh" > /etc/sudoers.d/$USER_SUDO_USER_USERNAME-commands
    # Protect sudoers files
    chmod 440 /etc/sudoers.d/*
    # verify sudoers syntax is valid
    if visudo -c; then
        echo "  Sudoers file is valid."
    else
        echo "  [!] Error: Sudoers file has errors."
        exit 1
    fi

    echo ""
    echo "--- 15. Override update timer settings ---"
    mkdir -p /etc/systemd/system/apt-daily.timer.d/
    echo -e "[Timer]\nOnCalendar=*-*-* ${AUTO_UPDATE_DAILY_HOUR},${AUTO_UPDATE_DAILY_HOUR_2}:00" > /etc/systemd/system/apt-daily.timer.d/override.conf
    mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d/
    echo -e "[Timer]\nOnCalendar=*-*-* ${AUTO_UPGRADE_DAILY_HOUR}:00" > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf
    systemctl daemon-reload

    echo ""
    echo "--- 16. Configure system file limits ---"
    echo "  Writing file limits to /etc/security/limits.d/xlvisuals.conf"
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
    echo "  Writing sysctl kernel parameters to /etc/sysctl.d/99-xlvisuals.conf"
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

    echo "  Applying sysctl changes"
    sysctl --system

    echo "  Writing modprobe parameters to mitigate CVE-2026-31431 and Dirty Frag to /etc/modprobe.d/dirty-frag.conf"
    rm -f /etc/modprobe.d/dirty-frag.conf
    cat <<'EOF' > /etc/modprobe.d/dirty-frag.conf
# Disable vulnerable crypto/net modules to mitigate CVE-2026-31431 and Dirty Frag
install algif_aead /bin/false
install af_alg /bin/false
install esp4 /bin/false
install esp6 /bin/false
install rxrpc /bin/false
EOF

    echo "  Force kernel to read new rules"
    sudo update-initramfs -u -k all

    echo "  Check kernel module status (should say \"install\")"
    modprobe -n -v algif_aead esp4 esp6 rxrpc

    echo ""
    echo "--- 18. Secure Shared Memory ---"
    # allow MySQL to write to the memory space, but prevents an attacker from running executables or gain root
    if ! grep -q "none /run/shm tmpfs" /etc/fstab; then
        echo "none /run/shm tmpfs defaults,nosuid,nodev,noexec 0 0" >> /etc/fstab
        echo "  Modified /etc/fstab"
    fi
    # Re-mount immediately to apply changes without reboot
    mount -o remount,nosuid,nodev,noexec /run/shm 2>/dev/null || true
    echo "  Remounted /run/shm"


    echo ""
    echo "--- 19. Configure needrestart ---"
    # Set needrestart to automatic mode so kernel upgrades and service restarts never prompt during unattended runs
    if [[ -f /etc/needrestart/needrestart.conf ]]; then
        sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf \
            && echo "  needrestart set to automatic mode" \
            || echo "  [!] Warning: could not update needrestart.conf"
    fi

    echo ""
    echo "--- 20. Configure timeouts ---"
    # Set apt timeout so apt doesn't hang waiting on a temporarily unavailable mirror
    echo "  setting apt timeout set to 5s with no retries in /etc/apt/apt.conf.d/99timeout"
    echo -e "Acquire::http::Timeout \"5\";\nAcquire::https::Timeout \"5\";\nAcquire::Retries \"0\";" > /etc/apt/apt.conf.d/99timeout


    echo ""
    echo "--- 21. Ubuntu Pro ---"
    if [[ "$UBUNTU_PRO_ATTACHED" == "y" ]]; then
        echo "  Ubuntu Pro already attached — no changes"
    elif [[ "$CONFIGURE_UBUNTU_PRO" =~ ^[Yy]$ ]] && [[ -n "$UBUNTU_PRO_TOKEN" ]]; then
        echo "  Attaching Ubuntu Pro ..."
        if pro attach "$UBUNTU_PRO_TOKEN"; then
            echo "  [V] Ubuntu Pro attached successfully"
            echo "  Enabling ESM-Apps and ESM-Infra ..."
            pro enable esm-apps 2>/dev/null || true
            pro enable esm-infra 2>/dev/null || true
        else
            echo "  [!] Ubuntu Pro attach failed — check token and try manually: sudo pro attach <token>"
        fi
    else
        # Not attached and not attaching — disable background Pro services to reduce noise
        # Removing Ubuntu Pro can cause issues with apt on Ubuntu since it's fairly integrated.
        # Safer to just disable the services.
        echo "  Ubuntu Pro not attached — disabling Pro services"
        pro config set apt_news=false 2>/dev/null || true
        systemctl stop ubuntu-advantage ubuntu-pro-esm-cache.service ubuntu-pro-apt-news.service 2>/dev/null || true
        systemctl mask ubuntu-pro-esm-cache.service ubuntu-pro-apt-news.service 2>/dev/null || true
    fi


    echo ""
    echo " --- 22. Disabling noisy MOTD components ---"
    for f in \
        /etc/update-motd.d/10-help-text \
        /etc/update-motd.d/50-motd-news \
        /etc/update-motd.d/85-fwupd \
        /etc/update-motd.d/91-contract-ua-esm-status \
        /etc/update-motd.d/91-release-upgrade \
        /etc/update-motd.d/95-hwe-eol \
        /etc/update-motd.d/97-overlayroot \
        /etc/update-motd.d/98-fsck-at-reboot \
        /etc/update-motd.d/99-livepatch-kernel-upgrade-required; do
        [[ -f "$f" ]] && chmod -x "$f" && echo "  [-] Disabled: $(basename $f)"
    done
    systemctl disable --now motd-news.timer 2>/dev/null || true
    rm -f /var/cache/motd-news
    echo "  [V] MOTD noise disabled"

else
    echo ""
    echo "--- 13.-22. System Tuning ---"
    echo "  Skipping system tuning steps."
fi


echo ""
echo "--- 23. CIS Level 1 Hardening ---"
if [[ "${CONFIGURE_CIS_HARDENING:-}" =~ ^[Yy]$ ]]; then

    echo ""
    echo "  [CIS] Removing insecure packages (ftp, telnet) ..."
    apt-get purge -y ftp tnftp telnet 2>/dev/null || true

    echo ""
    echo "  [CIS] Disabling Apport crash reporting ..."
    systemctl disable --now apport.service 2>/dev/null || true
    systemctl mask apport.service 2>/dev/null || true

    echo ""
    echo "  [CIS] Installing pam_pwquality ..."
    wait_for_apt
    apt_install libpam-pwquality || true

    echo ""
    echo "  [CIS] Configuring password quality (pwquality.conf) ..."
#    cat <<'EOF' > /etc/security/pwquality.conf
## CIS Level 1 - Password quality requirements
#minlen = 14
#dcredit = -1
#ucredit = -1
#ocredit = -1
#lcredit = -1
#maxrepeat = 3
#EOF

    echo "    CIS exception: minclass=3, maxrepeat=5 to accommodate passphrase-style"
    echo "    passwords with repeated separator characters (e.g. hyphens in passphrases)"
    cat <<'EOF' > /etc/security/pwquality.conf
# Password quality requirements
# CIS exception: minclass=3, maxrepeat=5 to accommodate passphrase-style
# passwords with repeated separator characters (e.g. hyphens in passphrases)
minlen = 14
minclass = 3
maxrepeat = 5
maxsequence = 4
EOF

echo ""
echo "  [CIS] Configuring pam_pwquality and pam_pwhistory in common-password ..."

    # Idempotent: only modify if our marker isn't already present
    if ! grep -q '# CIS-MANAGED' /etc/pam.d/common-password; then
        # Back up original
        cp /etc/pam.d/common-password /etc/pam.d/common-password.pre-cis

        # Insert ABOVE the existing pam_unix line, in correct order:
        # pwquality must come first so the token exists for pwhistory and pam_unix
        sed -i '/pam_unix.so/i \
password        requisite                       pam_pwquality.so retry=3\
password        required                        pam_pwhistory.so remember=5 use_authtok' \
            /etc/pam.d/common-password

        # Add use_authtok to pam_unix only once
        sed -i '/pam_unix.so/ { /use_authtok/! s/$/ use_authtok/ }' /etc/pam.d/common-password

        # Mark as managed
        echo '# CIS-MANAGED' >> /etc/pam.d/common-password
    fi

    echo ""
    echo "  [CIS] Configuring pam_faillock (account lockout after failed attempts) ..."
    if ! grep -q '# CIS-MANAGED' /etc/pam.d/common-auth; then
        cp /etc/pam.d/common-auth /etc/pam.d/common-auth.pre-cis

        # Insert authfail and authsucc immediately after the pam_unix line
        sed -i '/pam_unix.so/a \
auth        [default=die]                   pam_faillock.so authfail deny=5 unlock_time=900\
auth        sufficient                      pam_faillock.so authsucc deny=5 unlock_time=900' \
            /etc/pam.d/common-auth

        # Insert preauth before the pam_unix line
        sed -i '/pam_unix.so/i \
auth        required                        pam_faillock.so preauth silent deny=5 unlock_time=900' \
            /etc/pam.d/common-auth

        # Mark as managed
        echo '# CIS-MANAGED' >> /etc/pam.d/common-auth
    fi
    # Also configure faillock.conf for permanence
    cat <<'EOF' > /etc/security/faillock.conf
# CIS Level 1 - Account lockout policy
deny = 5
unlock_time = 900
silent
EOF

    echo ""
    echo "  [CIS] Setting password maximum age and expiry defaults in login.defs ..."
    sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   365/' /etc/login.defs
    sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/'   /etc/login.defs
    sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/'  /etc/login.defs
    # Apply max age to existing non-system accounts
    awk -F: '($3 >= 1000 && $1 != "nobody") {print $1}' /etc/passwd | while read -r USER_ACCOUNT; do
        chage --maxdays 365 --mindays 1 --warndays 14 "$USER_ACCOUNT" 2>/dev/null || true
    done

    echo ""
    echo "  [CIS] Setting account inactivity lock (30 days after password expiry) ..."
    useradd -D -f 30
    # Apply to existing non-system accounts
    awk -F: '($3 >= 1000 && $1 != "nobody") {print $1}' /etc/passwd | while read -r USER_ACCOUNT; do
        chage --inactive 30 "$USER_ACCOUNT" 2>/dev/null || true
    done

    echo ""
    echo "  [CIS] Setting default umask to 027 ..."
    # login.defs
    sed -i 's/^UMASK.*/UMASK           027/' /etc/login.defs
    # /etc/profile
    if grep -q '^umask' /etc/profile; then
        sed -i 's/^umask.*/umask 027/' /etc/profile
    else
        echo 'umask 027' >> /etc/profile
    fi
    # /etc/bash.bashrc
    if grep -q '^umask' /etc/bash.bashrc; then
        sed -i 's/^umask.*/umask 027/' /etc/bash.bashrc
    else
        echo 'umask 027' >> /etc/bash.bashrc
    fi

    echo ""
    echo "  [CIS] Restricting su to wheel group (pam_wheel) ..."
    # Create wheel group if it doesn't exist, ensure it's empty
    groupadd -f wheel
    # Remove all members from wheel — only explicitly added users should be in it
    grpck -r 2>/dev/null || true
    # Configure pam_wheel in su PAM config
    if ! grep -q 'pam_wheel' /etc/pam.d/su; then
        sed -i '1s/^/auth            required        pam_wheel.so use_uid group=wheel\n/' /etc/pam.d/su
    fi

    echo ""
    echo "  [CIS] Ensuring system accounts do not have a login shell ..."
    # Build exclusion list for service accounts that need a shell
    SHELL_LOCK_EXCLUDE="nobody"
    [[ "$INSTALL_FORGEJO" =~ ^[Yy]$ || "$ISINSTALLED_FORGEJO" == "y" ]] && SHELL_LOCK_EXCLUDE="$SHELL_LOCK_EXCLUDE|forgejo"
    # Add other services here as needed e.g:
    # [[ "$INSTALL_GITLAB" =~ ^[Yy]$ ]] && SHELL_LOCK_EXCLUDE="$SHELL_LOCK_EXCLUDE|git"

    awk -F: -v exclude="$SHELL_LOCK_EXCLUDE" \
        '($3 < 1000 && $7 != "/usr/sbin/nologin" && $7 != "/bin/false" && $7 != "/sbin/nologin") {
            split(exclude, ex, "|")
            for (i in ex) if ($1 == ex[i]) next
            if ($1 != "root") print $1
        }' /etc/passwd | while read -r SYS_ACCOUNT; do
        usermod -s /usr/sbin/nologin "$SYS_ACCOUNT" 2>/dev/null \
            && echo "  Locked shell for system account: $SYS_ACCOUNT" || true
    done

    echo ""
    echo "  [CIS] Setting cron and at directory permissions ..."
    chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly 2>/dev/null || true
    chmod 600 /etc/crontab 2>/dev/null || true
    chown root:root /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly /etc/crontab 2>/dev/null || true

    echo ""
    echo "  [CIS] Creating /etc/cron.allow and /etc/at.allow (restrict to root only) ..."
    echo "root" > /etc/cron.allow
    [[ -n "$USER_SUDO_USER_USERNAME" ]] && echo "$USER_SUDO_USER_USERNAME" >> /etc/cron.allow
    chmod 644 /etc/cron.allow
    chown root:root /etc/cron.allow
    echo "root" > /etc/at.allow
    chmod 600 /etc/at.allow
    chown root:root /etc/at.allow
    rm -f /etc/cron.deny /etc/at.deny 2>/dev/null || true

    echo ""
    echo "  [CIS] Setting SSH config file permissions ..."
    chmod 600 /etc/ssh/sshd_config 2>/dev/null || true
    find /etc/ssh/sshd_config.d/ -type f -name '*.conf' -exec chmod 600 {} \; 2>/dev/null || true

    echo ""
    echo "  [CIS] Hardening SSH server settings ..."
    # Write additional SSH hardening into our drop-in file $SSH_HARDENED_CONF

    # Each directive only added if not already present
    declare -A CIS_SSH_SETTINGS=(
        [LogLevel]="INFO"
        [Banner]="/etc/issue.net"
        [HostbasedAuthentication]="no"
        [PermitUserEnvironment]="no"
        [ClientAliveInterval]="300"
    )

    for KEY in "${!CIS_SSH_SETTINGS[@]}"; do
        VALUE="${CIS_SSH_SETTINGS[$KEY]}"
        if grep -qi "^${KEY}" "$CIS_SSH_CONF"; then
            # Already set by default hardening — skip
            echo "  [=] Already set: $KEY"
        else
            echo "$KEY $VALUE" >> "$CIS_SSH_CONF"
            echo "  [+] Added: $KEY $VALUE"
        fi
    done

    # Ciphers/MACs/KexAlgorithms — always overwrite since CIS is more specific
    grep -qi "^Ciphers" "$CIS_SSH_CONF" || \
        echo "Ciphers aes128-ctr,aes192-ctr,aes256-ctr,aes128-gcm@openssh.com,aes256-gcm@openssh.com" \
        >> "$CIS_SSH_CONF"

    grep -qi "^MACs" "$CIS_SSH_CONF" || \
        echo "MACs hmac-sha2-256,hmac-sha2-512,hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com" \
        >> "$CIS_SSH_CONF"

    grep -qi "^KexAlgorithms" "$CIS_SSH_CONF" || \
        echo "KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521" \
        >> "$CIS_SSH_CONF"
    # Create SSH warning banner
    cat <<'EOF' > /etc/issue.net
Authorized access only. All activity may be monitored and reported.
EOF
    systemctl restart ssh || true

    echo ""
    echo "  [CIS] Adding sudo logfile ..."
    if [[ "$VERSION_ID" == "26.04" ]]; then
        # Ubuntu 26.04 ships sudo-rs which does not support the 'logfile' Defaults directive.
        # sudo-rs logs natively to journald, captured by auditd and Wazuh — no drop-in needed.
        echo "  Ubuntu 26.04 detected (sudo-rs) — skipping sudo logfile drop-in; journald handles sudo logging."
        rm -f /etc/sudoers.d/cis-sudo-logfile 2>/dev/null || true
    else
        echo 'Defaults logfile="/var/log/sudo.log"' > /etc/sudoers.d/cis-sudo-logfile
        chmod 440 /etc/sudoers.d/cis-sudo-logfile
        visudo -c && echo "  Sudoers syntax valid." || echo "  [!] Sudoers syntax error — check /etc/sudoers.d/cis-sudo-logfile"
    fi

    echo ""
    echo "  [CIS] Disabling core dumps ..."
    # PAM limits
    echo '* hard core 0' > /etc/security/limits.d/cis-coredumps.conf
    # sysctl
    echo 'fs.suid_dumpable = 0' > /etc/sysctl.d/98-cis-coredumps.conf
    sysctl -w fs.suid_dumpable=0 2>/dev/null || true
    # systemd
    mkdir -p /etc/systemd/coredump.conf.d
    cat <<'EOF' > /etc/systemd/coredump.conf.d/cis.conf
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

    echo ""
    echo "  [CIS] Configuring sysctl CIS additions ..."
    cat <<'EOF' > /etc/sysctl.d/98-cis-hardening.conf
# CIS Level 1 sysctl hardening

# ASLR - randomize virtual address space
kernel.randomize_va_space = 2

# TCP SYN flood protection
net.ipv4.tcp_syncookies = 1

# Log martian packets (unexpected source addresses)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Disable secure ICMP redirects
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

# Disable sending ICMP redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Disable source routed packets (default interface)
net.ipv4.conf.default.accept_source_route = 0

# Disable IP forwarding
net.ipv4.ip_forward = 0

# IPv6 hardening
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.forwarding = 0
EOF
    sysctl --system

    echo ""
    echo "  [CIS] Blacklisting unused filesystem and USB storage modules ..."
    cat <<'EOF' > /etc/modprobe.d/cis-blacklist.conf
# CIS Level 1 - Disable unused filesystem modules
install cramfs /bin/false
blacklist cramfs
install freevxfs /bin/false
blacklist freevxfs
install hfs /bin/false
blacklist hfs
install hfsplus /bin/false
blacklist hfsplus
install jffs2 /bin/false
blacklist jffs2
install udf /bin/false
blacklist udf

# CIS Level 1 - Disable USB storage
install usb-storage /bin/false
blacklist usb-storage
EOF

    echo ""
    echo "  [CIS] Configuring /dev/shm mount options (nodev, nosuid, noexec) ..."
    if grep -q '/dev/shm' /etc/fstab; then
        # Update existing entry to ensure all three options are present
        sed -i '/\/dev\/shm/ s/defaults/defaults,nodev,nosuid,noexec/' /etc/fstab
        # Avoid duplicating options on re-runs
        sed -i '/\/dev\/shm/ s/\(nodev,nosuid,noexec\)\(.*\)\1/\1\2/' /etc/fstab
    else
        echo 'tmpfs /dev/shm tmpfs defaults,nodev,nosuid,noexec 0 0' >> /etc/fstab
    fi
    mount -o remount /dev/shm 2>/dev/null || true

    echo ""
    echo "  [CIS] Configuring journald to forward to rsyslog ..."
    mkdir -p /etc/systemd/journald.conf.d
    cat <<'EOF' > /etc/systemd/journald.conf.d/cis.conf
[Journal]
ForwardToSyslog=yes
EOF
    systemctl restart systemd-journald || true

    echo ""
    echo "  [CIS] Configuring NTP via systemd-timesyncd ..."
    mkdir -p /etc/systemd/timesyncd.conf.d
    cat <<'EOF' > /etc/systemd/timesyncd.conf.d/cis.conf
[Time]
NTP=0.ubuntu.pool.ntp.org 1.ubuntu.pool.ntp.org 2.ubuntu.pool.ntp.org 3.ubuntu.pool.ntp.org
FallbackNTP=ntp.ubuntu.com
EOF
    systemctl restart systemd-timesyncd || true

    echo ""
    echo "  [CIS] Setting interactive session timeout (TMOUT=900) ..."
    cat <<'EOF' > /etc/profile.d/cis-timeout.conf
# CIS Level 1 - Auto-logout idle interactive sessions after 15 minutes
TMOUT=900
readonly TMOUT
export TMOUT
EOF

    echo ""
    echo "  [CIS] File integrity monitoring (AIDE) ..."
    if [[ "$INSTALL_WAZUHAGENT" =~ ^[Yy]$ || "$ISINSTALLED_WAZUHAGENT" == "y" ]]; then
        echo "  Wazuh is installed/selected — skipping AIDE. Wazuh FIM provides equivalent"
        echo "  real-time file integrity monitoring via the Wazuh dashboard."
    else
        wait_for_apt
        if apt_install aide aide-common; then
            # Initialise the AIDE database (takes a few minutes on first run)
            echo "  Building AIDE database — this may take a few minutes ..."
            aideinit --yes 2>/dev/null || aideinit 2>/dev/null || true
            # Activate the database
            if [[ -f /var/lib/aide/aide.db.new ]]; then
                cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
                echo "  [V] AIDE database initialised at /var/lib/aide/aide.db"
            elif [[ -f /var/lib/aide/aide.db.new.gz ]]; then
                cp /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
                echo "  [V] AIDE database initialised at /var/lib/aide/aide.db.gz"
            else
                echo "  [!] AIDE database file not found — run 'sudo aideinit' manually after provisioning"
            fi
            # Add a daily cron job to check integrity
            cat <<'EOF' > /etc/cron.daily/aide-check
#!/bin/bash
/usr/bin/aide --check 2>&1 | mail -s "AIDE integrity check - $(hostname)" root
EOF
            chmod 700 /etc/cron.daily/aide-check
            chown root:root /etc/cron.daily/aide-check

            echo  "  AIDE installed. To uninstall AIDE, run:"
            echo  "    sudo apt-get purge -y aide aide-common"
            echo  "    sudo rm -rf /var/lib/aide /etc/aide /etc/aide.conf /etc/cron.daily/aide-check /var/log/aide"
        else
            echo "  [!] AIDE installation failed — skipping"
        fi
    fi

    echo ""
    echo "  [CIS] Configuring Postfix to listen on loopback only ..."
    if [[ "$ISINSTALLED_POSTFIX" == "y" ]] || [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ ]]; then
        postconf -e 'inet_interfaces = loopback-only' 2>/dev/null || true
        echo "  inet_interfaces = loopback-only set"
    else
        echo "  Postfix not installed — skipping"
    fi

    echo ""
    echo "  [CIS] Setting up Monit password expiry alert for sudo user ..."
    if [[ "$INSTALL_MONIT" =~ ^[Yy]$ || "$ISINSTALLED_MONIT" == "y" ]] && [[ -n "$USER_SUDO_USER_USERNAME" ]]; then
        # Copy and configure the companion check script
        cp "$CONFIG_DIR/usr/local/bin/check-password-expiry.sh" /usr/local/bin/check-password-expiry.sh
        sed -i "s|%%USER_SUDO_USER_USERNAME%%|$USER_SUDO_USER_USERNAME|g" /usr/local/bin/check-password-expiry.sh
        chmod 750 /usr/local/bin/check-password-expiry.sh
        chown root:root /usr/local/bin/check-password-expiry.sh

        # Copy the Monit check config and enable it
        cp "$CONFIG_DIR/etc/monit/conf-available/password-expiry" /etc/monit/conf-available/password-expiry
        ln -sf /etc/monit/conf-available/password-expiry /etc/monit/conf-enabled/password-expiry
        echo "  [V] Monit password expiry check configured for user: $USER_SUDO_USER_USERNAME"
    else
        echo "  Monit not installed/selected or no sudo user set — skipping password expiry check"
    fi

    echo ""
    echo "  [CIS] CIS Level 1 hardening complete."

else
    echo "  Skipping CIS hardening."
fi


echo ""
echo "--- 24. Install fonts ---"
if [[ "$INSTALL_FONTS" =~ ^[Yy]$ ]]; then
    # install fonts
    wait_for_apt
    if apt_install fonts-liberation fonts-freefont-ttf; then
        echo "  Installed Liberation and Freefont fonts."
    fi;
    if [[ "$INSTALL_MS_FONTS" =~ ^[Yy]$ ]]; then
        echo ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true | debconf-set-selections
        if apt_install ttf-mscorefonts-installer; then
            echo "  Installed Microsoft fonts."
        fi
    fi
    fc-cache -f -v
else
    echo "  Skipping fonts installation."
fi


echo ""
echo "--- 25. Install Python 3.14 ---"
if [[ "$INSTALL_CPYTHON314" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_CPYTHON314" == 'reinstall' ]]; then
        echo "  Uninstall Python 3.14"
        wait_for_apt
        apt-get purge -y python3.14-full python3.14-venv pipx || true
    fi

    if [[ "$VERSION_ID" == "24.04" ]]; then
        # On Ubuntu 24.04, system python is 3.12. Install 3.14 via deadsnakes PPA.
        wait_for_apt
        if add-apt-repository -y ppa:deadsnakes/ppa 2>&1; then
            apt-get update
            if apt_install python3.14-full python3.14-venv pipx; then

                # Keep 3.12 as default, 3.14 available explicitly via python3.14
                if command -v python3.12 &>/dev/null; then
                    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 2
                    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.14 1
                fi
            fi
        else
            echo "  [!] Warning: deadsnakes PPA unavailable — skipping Python 3.14 installation"
            APT_PACKAGES_NOT_INSTALLED+=("python3.14-full" "python3.14-venv" "pipx")
        fi

    elif [[ "$VERSION_ID" == "26.04" ]]; then
        # On Ubuntu 26.04, system python is 3.14. Just ensure venv and pipx are present.
        wait_for_apt
        apt_install python3.14-venv pipx || true
    fi

    # Install virtualenv globally via pipx
    # pipx installs tools in isolated pockets, avoiding conflicts with system python
    pipx install virtualenv --include-deps --force

    VIRTUALENV_BIN=$(find /root/.local/bin /usr/local/bin -name virtualenv 2>/dev/null | head -n1)
    if [[ -n "$VIRTUALENV_BIN" && "$VIRTUALENV_BIN" != "/usr/local/bin/virtualenv" ]]; then
        ln -sf "$VIRTUALENV_BIN" /usr/local/bin/virtualenv
    fi

    echo "  Note: Python setuptools and wheel were NOT installed at the system level."
    echo "  Install them inside individual venvs as needed:"
    echo "     python3.14 -m venv /path/to/venv"
    echo "     source /path/to/venv/bin/activate"
    echo "     pip install setuptools wheel"

    echo "  Python 3.14 and packaging tools (pipx/virtualenv) installed."
else
    echo "  Skipping Python 3.14 installation."
fi


echo ""
echo "--- 26. Install PyPy 3.11 ---"
if [[ "$INSTALL_PYPY311" =~ ^[Yy]$ ]]; then

    # Fetch latest PyPy 3.11 version dynamically, fall back to known version if unavailable
    PYPY_ARCH=$(uname -m | sed 's/x86_64/linux64/;s/aarch64/aarch64/')  # linux64 or aarch64
    PYPY_BASE_URL="https://downloads.python.org/pypy"
    PYPY_FILENAME=$(curl -fsSL https://downloads.python.org/pypy/versions.json | grep -oP "pypy3\\.11-v[\\d.]+-${PYPY_ARCH}\\.tar\\.bz2" | sort -V | tail -n1) || true
    if [[ -z "$PYPY_FILENAME" ]]; then
        echo "  Could not determine latest PyPy 3.11 version. Falling back to $PYPY_FALLBACK_VERSION on ${PYPY_ARCH}."
        PYPY_FILENAME="${PYPY_FALLBACK_VERSION}-${PYPY_ARCH}.tar.bz2"
    fi

    PYPY_DIRNAME="${PYPY_FILENAME%.tar.bz2}"
    echo "  Installing PyPy 3.11 ($PYPY_DIRNAME) to /opt"
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

    echo "  Note: PyPy setuptools and wheel were NOT installed at the system level."
    echo "  Install them inside individual venvs as needed:"
    echo "     pypy3.11 -m venv /path/to/venv"
    echo "     source /path/to/venv/bin/activate"
    echo "     pip install setuptools wheel"

    popd > /dev/null
    echo "  PyPy 3.11 installation complete."
else
    echo "  Skipping PyPy installation."
fi


echo ""
echo "--- 27. Install weasyprint ---"
if [[ "$INSTALL_WEASYPRINT" =~ ^[Yy]$ ]]; then
    wait_for_apt
    apt_install weasyprint || true
else
    echo "  Skipping weasyprint installation."
fi


echo ""
echo "--- 28. Install imagemagick ---"
if [[ "$INSTALL_IMAGEMAGICK" =~ ^[Yy]$ ]]; then
    wait_for_apt
    apt_install imagemagick || true
else
    echo "  Skipping imagemagick installation."
fi


echo ""
echo "--- 29. Install nginx ---"
if [[ "$INSTALL_NGINX" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_NGINX" == 'reinstall' ]]; then
        echo "  Uninstall nginx"
        wait_for_apt
        apt-get purge -y nginx || true
    fi
    wait_for_apt
    # apache2-utils needed for htpasswd utility
    apt_install nginx apache2-utils || true
    usermod -a -G $USER_SUDO_USER_USERNAME www-data
    systemctl enable --now nginx || true

    # log version and installed modules
    echo "  Installed nginx:"
    nginx -V || true

    if command -v ufw >/dev/null && ufw status | grep -q active; then
        ufw allow 80/tcp
        ufw allow 443/tcp
    fi
else
    echo "  Skipping nginx installation."
fi


echo ""
echo "--- 30. Install Valkey ---"
if [[ "$INSTALL_VALKEY" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_VALKEY" == 'reinstall' ]]; then
        echo "  Uninstall valkey-server valkey-tools"
        wait_for_apt
        apt-get purge -y valkey-server valkey-tools || true
    fi
    wait_for_apt
    if apt_install valkey-server valkey-tools; then
        systemctl enable --now valkey-server || true
    fi
else
    echo "  Skipping Valkey installation."
fi


echo ""
echo "--- 31. Install MySQL ---"
if [[ "$INSTALL_MYSQL" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_MYSQL" == 'reinstall' ]]; then
        echo "  Uninstall mysql-server mysql-shell mysqltuner"
        apt-get purge -y mysql-server mysql-shell mysqltuner || true
    fi

    wait_for_apt
    if apt_install mysql-server mysql-shell mysqltuner; then
        systemctl enable --now mysql.service || echo "  [!] Warning: service failed to start"

        # Wait for MySQL to create the socket file before proceeding
        echo "  Waiting for MySQL to start..."
        MYSQL_READY=0
        for i in {1..6}; do
            if [ -S /var/run/mysqld/mysqld.sock ]; then
                MYSQL_READY=1
                break
            fi
            sleep 1
        done

        if [ "$MYSQL_READY" -ne 1 ]; then
            echo "  [!] Error: MySQL failed to start"
            exit 1
        fi

        # Secure MySQL using the provided password. Does the same as mysql_secure_installation
        mysql_root <<EOS
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${MYSQL_PASSWORD_ESCAPED}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOS

        mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql_root mysql

        # Create a passwordless read-only healthcheck user for the health check script. Needs no access to any table.
        mysql_root <<EOS
CREATE USER IF NOT EXISTS 'healthcheck'@'localhost';
FLUSH PRIVILEGES;
EOS

        echo "  MySQL root password set and security initialized."
    else
        echo "  [!] MySQL installation failed — skipping configuration"
    fi
else
    echo "  Skipping MySQL installation."

    if [[ "$ISINSTALLED_MYSQL" == "y" ]]; then
        # Check if MySQL is currently running before attempting to connect
        if systemctl is-active --quiet mysql.service; then
            echo "  Testing if healthcheck user exists..."

            # Execute the query inside the 'if' condition to protect it from 'set -e'
            if mysql -u healthcheck -e "SELECT 1" &>/dev/null; then
                echo "  [+] Success: 'healthcheck' user exists."
            else
                echo "  [!] Warning: 'healthcheck' user does not exist or credentials are invalid."
            fi
        else
            echo "  [!] Warning: MySQL service is not running. Could not verify healthcheck user."
        fi
    fi
fi

echo ""
echo "--- 32. Install MariaDB ---"
if [[ "$INSTALL_MARIADB" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_MARIADB" == 'reinstall' ]]; then
        echo "  Uninstall mariadb-server"
        apt-get purge -y mariadb-server mariadb-client mysqltuner || true
    fi

    wait_for_apt
    if apt_install mariadb-server mariadb-client mysqltuner; then
        systemctl enable --now mariadb.service || echo "Warning: service failed to start"

        echo "  Waiting for MariaDB to start..."
        MYSQL_READY=0
        for i in {1..6}; do
            if [ -S /var/run/mysqld/mysqld.sock ]; then
                MYSQL_READY=1
                break
            fi
            sleep 1
        done

        if [ "$MYSQL_READY" -ne 1 ]; then
            echo "  [!] Error: MariaDB failed to start"
            exit 1
        fi

        # Secure MariaDB — uses mysql_native_password (caching_sha2_password not supported)
        mysql_root <<EOS
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${MYSQL_PASSWORD_ESCAPED}');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOS

        mariadb-tzinfo-to-sql /usr/share/zoneinfo | mysql_root mysql

        # Create a passwordless read-only healthcheck user for the health check script. Needs no access to any table.
        mysql_root <<EOS
CREATE USER IF NOT EXISTS 'healthcheck'@'localhost';
FLUSH PRIVILEGES;
EOS
        echo "  MariaDB root password set and security initialized."

        # Create MySQL compatibility symlinks for operator convenience.
        # mariadb-client-compat (which provides these) is only available from Ubuntu 25.04+,
        # so we create them manually on all supported releases for consistency.
        echo "  Creating MySQL compatibility symlinks..."
        declare -A MARIADB_COMPAT_MAP=(
            ["mysql"]="mariadb"
            ["mysqladmin"]="mariadb-admin"
            ["mysqldump"]="mariadb-dump"
            ["mysqlcheck"]="mariadb-check"
            ["mysqlimport"]="mariadb-import"
            ["mysqlshow"]="mariadb-show"
            ["mysqlslap"]="mariadb-slap"
            ["mysql_secure_installation"]="mariadb-secure-installation"
            ["mysql_tzinfo_to_sql"]="mariadb-tzinfo-to-sql"
        )
        for mysql_cmd in "${!MARIADB_COMPAT_MAP[@]}"; do
            mariadb_cmd="${MARIADB_COMPAT_MAP[$mysql_cmd]}"
            if command -v "$mariadb_cmd" &>/dev/null && ! command -v "$mysql_cmd" &>/dev/null; then
                ln -sf "$(command -v $mariadb_cmd)" "/usr/local/bin/$mysql_cmd"
                echo "  [+] $mysql_cmd -> $mariadb_cmd"
            fi
        done
    else
        echo "  [!] MariaDB installation failed — skipping configuration"
    fi
else
    echo "  Skipping MariaDB installation."

    if [[ "$ISINSTALLED_MARIADB" == "y" ]]; then
        # Check if MariaDB is currently running before attempting to connect

        if systemctl is-active --quiet mariadb.service; then
            echo "  Testing if healthcheck user exists..."

            # Execute the client query inside the 'if' condition to protect it from 'set -e'
            if mariadb -u healthcheck -e "SELECT 1" &>/dev/null; then
                echo "  [+] Success: 'healthcheck' user exists."
            else
                echo "  [!] Warning: 'healthcheck' user does not exist or credentials are invalid."
            fi
        else
            echo "  [!] Warning: MariaDB service is not running. Could not verify healthcheck user."
        fi
    fi
fi

echo ""
echo "--- 33. Install PostgreSQL $PG_VERSION ---"
if [[ "$INSTALL_POSTGRESQL" =~ ^[Yy]$ ]]; then

    if [[ "$PROMPT_POSTGRESQL" == 'reinstall' ]]; then
        echo "  Uninstall postgresql-$PG_VERSION postgresql-client-$PG_VERSION"
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
        apt-get update

        # Prevent automatically installing v16 by using one of the two:
        # apt_install postgresql-$PG_VERSION postgresql-client-$PG_VERSION --no-install-recommends
        # apt-get purge -y postgresql-16 || true

        # Install PostgreSQL 18
        if apt_install postgresql-$PG_VERSION; then
            apt_install postgresql-client-$PG_VERSION || true

            # Optional: Install Useful PostgreSQL Tools
            apt_install postgresql-$PG_VERSION-pgaudit postgresql-$PG_VERSION-postgis-3 || true

            echo "  PostgreSQL version installed:"
            psql --version

            # Detect cluster path
            PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
            PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

            echo "  Backing up configuration..."
            cp "$PG_CONF" "${PG_CONF}.bak"
            cp "$PG_HBA" "${PG_HBA}.bak"

            echo "  Enabling PostgreSQL..."
            systemctl enable --now postgresql || echo "Warning: service failed to start"
        else
            echo "  [!] PostgreSQL ${PG_VERSION} installation failed — skipping configuration"
        fi

    else
        echo "  Could not download gpg key. Skipping installation."
    fi
else
    echo "  Skipping PostgreSQL installation."
fi


echo ""
echo "--- 34. Install Mosquitto MQTT broker ---"
if [[ "$INSTALL_MOSQUITTO" =~ ^[Yy]$ ]]; then

    if [[ "$PROMPT_MOSQUITTO" == 'reinstall' ]]; then
        echo "  Uninstall mosquitto mosquitto-clients"
        wait_for_apt
        apt-get purge -y mosquitto mosquitto-clients  || true
    fi

    wait_for_apt
    if apt_install mosquitto mosquitto-clients; then
        mkdir -p /var/log/mosquitto/ /var/run/mosquitto/
        chown mosquitto: /var/log/mosquitto

        systemctl enable --now mosquitto.service || echo "Warning: service failed to start"
    else
        echo "  [!] mosquitto installation failed — skipping configuration"
    fi
else
    echo "  Skipping Mosquitto MQTT broker installation."
fi


echo ""
echo "--- 35. Install Postfix (relay-only) ---"
if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ ]]; then

    if [[ "$PROMPT_POSTFIX" == 'reinstall' ]]; then
        echo "  Uninstall postfix"
        wait_for_apt
        apt-get purge -y postfix mailutils libsasl2-modules || true
        rm -rf /etc/postfix || true
    fi

    wait_for_apt
    if apt_install postfix mailutils libsasl2-modules; then

        # Postfix config is applied after installation alongside other services.
        # We just ensure the service is enabled here; section 36 restarts it
        # after main.cf and sasl_passwd are in place.
        systemctl enable postfix || echo "Warning: could not enable postfix"
    else
        echo "  [!] postfix installation failed — skipping configuration"
    fi
else
    echo "  Skipping Postfix installation."
fi


echo ""
echo "--- 36. Install Monit ---"
if [[ "$INSTALL_MONIT" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_MONIT" == 'reinstall' ]]; then
        echo "  Uninstall monit"
        rm -rf /etc/monit/conf-enabled
        wait_for_apt
        apt-get purge -y monit  || true
    fi
    wait_for_apt
    if apt_install monit; then
        systemctl enable --now monit.service || echo "Warning: service failed to start"
    else
        echo "  [!] monit installation failed — skipping configuration"
    fi
else
    echo "  Skipping Monit installation."
fi


echo ""
echo "--- 37. Install Webmin ---"
if [[ "$INSTALL_WEBMIN" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_WEBMIN" == 'reinstall' ]]; then
        echo "  Uninstall webmin"
        wait_for_apt
        apt-get purge -y webmin || true
    fi

    WEBMIN_INSTALLED=n

    # Try repo install via official setup script
    curl -fsSL --max-time 30 https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh \
        -o /tmp/webmin-setup-repo.sh 2>/dev/null || true

    if [[ -f /tmp/webmin-setup-repo.sh && -s /tmp/webmin-setup-repo.sh ]]; then
        sh /tmp/webmin-setup-repo.sh --force || true
        rm -f /tmp/webmin-setup-repo.sh
        wait_for_apt
        if apt_install webmin --install-recommends; then
            WEBMIN_INSTALLED=y
        else
            echo "  apt install failed — trying direct download..."
        fi
    else
        echo "  Could not download Webmin setup script — trying direct download..."
    fi

    # Fall back to direct download if repo install failed or setup script unavailable
    if [[ "$WEBMIN_INSTALLED" == "n" ]]; then
        echo "  Installing via https://webmin.com/download/deb/webmin-current.deb (SourceForge)"
        if curl -fsSL --max-time 60 "https://webmin.com/download/deb/webmin-current.deb" \
                -o /tmp/webmin-current.deb 2>/dev/null; then
            dpkg -i /tmp/webmin-current.deb || true
            apt-get install -f -y || true
            rm -f /tmp/webmin-current.deb
            WEBMIN_INSTALLED=y
            echo "  [V] Webmin installed via direct download"
        else
            echo "  [!] Webmin direct download also failed"
            APT_PACKAGES_NOT_INSTALLED+=("webmin")
        fi
    fi

    if [[ "$WEBMIN_INSTALLED" == "y" ]]; then
        systemctl enable --now webmin.service \
            && echo "  [V] Webmin service started" \
            || echo "  [!] Warning: Webmin service failed to start"
    fi
else
    echo "  Skipping Webmin installation."
fi


echo ""
echo "--- 38. Install Grafana ---"
if [[ "$INSTALL_GRAFANA" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_GRAFANA" == 'reinstall' ]]; then
        echo "  Uninstall grafana"
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
        if apt_install grafana; then
            # ensure group grafana exists
            if ! getent group grafana >/dev/null; then
                groupadd grafana
            fi
            usermod -a -G grafana $USER_SUDO_USER_USERNAME
            systemctl enable --now grafana-server.service || echo "Warning: service failed to start"
        else
          echo "  [!] Grafana installation failed — skipping configuration"
        fi
    else
        echo "  Could not download gpg key. Skipping installation."
    fi
else
    echo "  Skipping Grafana installation."
fi


echo ""
echo "--- 39. Install Forgejo ---"
if [[ "$INSTALL_FORGEJO" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_FORGEJO" == 'reinstall' ]]; then
        echo "  Uninstall forgejo (deleting folders)"
        rm -f /usr/local/bin/forgejo || true
        rm -rf /var/lib/forgejo || true
        rm -rf /etc/forgejo || true
    fi

    if ! id "git" &>/dev/null; then
        echo "  Adding user git"
        adduser --system --shell /bin/bash --group --disabled-password --home /home/git git || true
    fi
    if ! getent group git >/dev/null; then
        echo "  Adding group git"
        groupadd git
    fi

    echo "  Determining latest forgejo version"
    rm -f forgejo-latest || true
    FORGEJO_LATEST=$(curl -s --max-time 10 https://codeberg.org/api/v1/repos/forgejo/forgejo/releases/latest 2>/dev/null \
    | jq -r .tag_name 2>/dev/null \
    | sed 's/v//' || true)

    if [[ -z "$FORGEJO_LATEST" ]]; then
        echo "  [!] Warning: could not determine latest Forgejo version — using fallback $FORGEJO_FALLBACK_VERSION"
        FORGEJO_LATEST="$FORGEJO_FALLBACK_VERSION"
    fi
    echo "  Downloading forgejo $FORGEJO_LATEST ..."
    FORGEJO_ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')   # amd64 or arm64
    wget -q -O forgejo-latest "https://codeberg.org/forgejo/forgejo/releases/download/v${FORGEJO_LATEST}/forgejo-${FORGEJO_LATEST}-linux-${FORGEJO_ARCH}" || true

    if [[ -f "forgejo-latest" &&  -s "forgejo-latest" ]]; then
        install -m 755 forgejo-latest /usr/local/bin/forgejo
        mkdir -p /var/lib/forgejo /etc/forgejo
        echo "  Forgejo $FORGEJO_LATEST installed"

        chown git:git /var/lib/forgejo && chmod 750 /var/lib/forgejo
        chown root:git /etc/forgejo && chmod 770 /etc/forgejo
        usermod -a -G git $USER_SUDO_USER_USERNAME

        # cleanup
        rm -f forgejo-latest || true

        # configure
        if [[ "$INSTALL_GRAFANA" =~ ^[Yy]$ || "$ISINSTALLED_GRAFANA" =~ ^[Yy]$ ]]; then
            # Grafana and Forgejo both use port 3000 by default. -> Change Forgejo port
            echo "  Installing Forgejo on port $FORGEJO_PORT"
            cat <<EOF > /etc/forgejo/app.ini
[server]
SSH_DOMAIN = $FORGEJO_DOMAIN
DOMAIN = $FORGEJO_DOMAIN
HTTP_PORT = $FORGEJO_PORT
ROOT_URL = http://$FORGEJO_DOMAIN:$FORGEJO_PORT/
EOF
        fi

        # make app.ini writeable for Forgejo so that it can update the configuration
        chown git:git /etc/forgejo/app.ini || true
        chmod 640 /etc/forgejo/app.ini || true

        # install systemd service script
        echo "  Installing Forgejo service script"
        rm -f /etc/systemd/system/forgejo.service || true
        wget -q -O /etc/systemd/system/forgejo.service https://codeberg.org/forgejo/forgejo/raw/branch/forgejo/contrib/systemd/forgejo.service || true
        if [[ -f "/etc/systemd/system/forgejo.service" && -s "/etc/systemd/system/forgejo.service" ]]; then
            # Increase startup timeout — Forgejo takes longer on first start
            # as it initialises the database and generates keys
            mkdir -p /etc/systemd/system/forgejo.service.d
            cat > /etc/systemd/system/forgejo.service.d/timeout.conf <<EOF
[Service]
TimeoutStartSec=120
EOF
            systemctl daemon-reload
            systemctl enable --now forgejo.service || echo "  [!] Warning: service failed to start"
        else
            echo "  Could not download service script. Skipping systemd setup for Forgejo."
        fi
    else
        echo "  Could not download Forgejo ${FORGEJO_LATEST}. Skipping installation."
    fi
else
    echo "  Skipping Forgejo installation."
fi
if [[ "$ISINSTALLED_FORGEJO" == "y" && -z "${FORGEJO_PORT:-}" ]]; then
    # Resolve FORGEJO_PORT from app.ini if not already set in conf or prompted
    FORGEJO_PORT=$(grep -oP '(?<=HTTP_PORT\s=\s)\d+' /etc/forgejo/app.ini 2>/dev/null || echo "3000")
fi
# Ensure FORGEJO_PORT always has a value to avoid unbound variable errors
FORGEJO_PORT="${FORGEJO_PORT:-3000}"

echo ""
echo "--- 40. Disable TCP Transmit Offloading ---"
if [[ "$DISABLE_TX_OFFLOAD" =~ ^[Yy]$ ]]; then

    if [[ -f $CONFIG_DIR/etc/systemd/system/disable-offload.service ]]; then
        cp $CONFIG_DIR/etc/systemd/system/disable-offload.service /etc/systemd/system/disable-offload.service
        sed -i "s|%%PRIMARY_INTERFACE%%|$PRIMARY_INTERFACE|g" /etc/systemd/system/disable-offload.service
        systemctl daemon-reload
        systemctl enable --now disable-offload.service \
            && echo "  TCP transmit offloading disabled on $PRIMARY_INTERFACE." \
            || echo "  [!] Warning: could not enable disable-offload service."
    else
        echo "  File $CONFIG_DIR/etc/systemd/system/disable-offload.service not found"
    fi
else
    echo "  Skipping TCP transmit offload configuration."
fi

echo ""
echo "--- 41. Install Fail2Ban ---"
if [[ "$INSTALL_FAIL2BAN" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_FAIL2BAN" == 'reinstall' ]]; then
        echo "  Uninstall fail2ban"
        wait_for_apt
        apt-get purge -y fail2ban  || true
    fi

    wait_for_apt
    if apt_install fail2ban; then
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
        echo "  [!] Fail2Ban installation failed — skipping configuration"
    fi
else
    echo "  Skipping Fail2Ban installation."
fi


echo ""
echo "--- 42. Install auditd ---"
if [[ "$INSTALL_AUDITD" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_AUDITD" == 'reinstall' ]]; then
        echo "  Uninstall auditd"
        wait_for_apt
        apt-get purge -y auditd  || true
    fi

    wait_for_apt
    if apt_install auditd; then
        systemctl enable --now auditd.service || echo "  [!] Warning: service failed to start"

        # Configuring Auditd Rules for Wazuh
        # Install a basic set of rules (e.g., tracking execve, file deletions, etc.)
        curl -s https://raw.githubusercontent.com/Neo23x0/auditd/master/audit.rules -o /etc/audit/rules.d/audit.rules

        # FIX: Comment out rules for users that don't exist on this system
        # This prevents the "Unknown user" errors from breaking the rule load
        sed -i 's/^-a always,exit -F arch=b64 -S connect -F auid>=1000 -F auid!=4294967295 -F key=export/#&/' /etc/audit/rules.d/audit.rules
        sed -i '/-u chrony/s/^/#/' /etc/audit/rules.d/audit.rules
        sed -i '/-u ntp/s/^/#/' /etc/audit/rules.d/audit.rules

        # increase the backlog limit
        echo "-b 8192" > /etc/audit/rules.d/00-backlog.conf

        # Load rules and capture any errors
        echo "  Loading audit rules..."
        AUGENRULES_OUTPUT=$(augenrules --load 2>&1) || true

        # Check for rule loading errors and report which lines/rules failed
        # Rules that fail to load are simply not active in the kernel — they're ignored.
        # The kernel audit subsystem loads rules sequentially and skips any it can't process
        RULE_ERRORS=$(echo "$AUGENRULES_OUTPUT" | grep -i "error\|No such file" || true)
        if [[ -n "$RULE_ERRORS" ]]; then
            echo "  [!] Some audit rules failed to load:"
            echo "$RULE_ERRORS" | while IFS= read -r line; do
                # Extract line number if present and show the offending rule
                LINENO_=$(echo "$line" | grep -oP '(?<=line )\d+' || true)
                if [[ -n "$LINENO_" ]]; then
                    RULE=$(sed -n "${LINENO_}p" /etc/audit/audit.rules 2>/dev/null || true)
                    echo "    line $LINENO_: $RULE"
                else
                    echo "    $line"
                fi
            done
            echo "  These rules will be skipped. Review /etc/audit/rules.d/audit.rules to fix."
        fi

        # Report final loaded rule count
        RULE_COUNT=$(auditctl -l 2>/dev/null | grep -c "^-" || true)
        echo "  [V] Audit rules loaded: $RULE_COUNT rules active"
        echo "  Run 'sudo auditctl -l' to see all loaded rules"
    else
        echo "  [!] auditd installation failed — skipping configuration"
    fi

else
    echo "  Skipping auditd installation."
fi


echo ""
echo "--- 43. Install ip blocklist (ipset + ipsum) ---"
if [[ "$INSTALL_IPBLOCK" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_IPBLOCK" == 'reinstall' ]]; then
        echo "  Uninstall ip blocklist"

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

        echo "  Remaining setlist:"
        ipset list -n || true
    fi

    wait_for_apt
    if apt_install ipset; then

        # Backup the original ufw after.init if not already backed up
        if [ ! -f /etc/ufw/after.init.orig ]; then
            echo "  Backing up the original ufw after.init to /etc/ufw/after.init.orig"
            cp /etc/ufw/after.init /etc/ufw/after.init.orig
        fi

        # Use a temporary directory for the git clone
        TEMP_DIR=$(mktemp -d)
        git clone https://github.com/poddmo/ufw-blocklist.git "$TEMP_DIR"

        # Install the ufw-blocklist files
        if [ -f "$TEMP_DIR/after.init" ]; then
            echo "  Installing the ufw-blocklist files"
            cp "$TEMP_DIR/after.init" /etc/ufw/after.init
            chown root:root /etc/ufw/after.init
            chmod 750 /etc/ufw/after.init
        fi
        if [ -f "$TEMP_DIR/ufw-blocklist-ipsum" ]; then
            echo "  Installing the ufw-blocklist cron job"
            cp "$TEMP_DIR/ufw-blocklist-ipsum" /etc/cron.daily/ufw-blocklist-ipsum
            chown root:root /etc/cron.daily/ufw-blocklist-ipsum
            chmod 750 /etc/cron.daily/ufw-blocklist-ipsum

            # Append save-to-file step so /etc/ipsum.4.txt stays in sync after
            # each cron run and is restored correctly after a reboot
            cat >> /etc/cron.daily/ufw-blocklist-ipsum << 'CRONEOF'

# Save current ipset to file for restoration after reboot
$ipset_exe save "$ipsetname" | grep "^add " | awk '{print $3}' > /etc/ipsum.4.txt
$logger "saved $cnt entries to /etc/ipsum.4.txt for boot restoration"
CRONEOF
        fi

        # Download an initial IP blocklist from IPsum (Level 4: IPs found in 4+ blacklists)
        echo "  Downloading initial setlist"
        curl -sS -f --compressed -o /etc/ipsum.4.txt 'https://raw.githubusercontent.com/stamparm/ipsum/master/levels/4.txt'
        chmod 640 /etc/ipsum.4.txt

        # Clean up temp directory
        rm -rf "$TEMP_DIR"

        # Initialize ipset and reload UFW to apply the blocklist
        /etc/ufw/after.init start

        # Ensure UFW is reloaded to recognize the new after.init logic
        ufw reload
    else
        echo "  [!] IP blocklist installation failed — skipping configuration"
    fi
else
    echo "  Skipping IP blocklist installation."
fi


echo ""
echo "--- 44. Install Suricata IDS ---"
if [[ "$INSTALL_SURICATA" =~ ^[Yy]$ ]]; then
    # The idea is that wazuh agent monitors /var/log/suricata/eve.json for attacks and responses are configured and triggered via wazuh manager

    if [[ "$PROMPT_SURICATA" == 'reinstall' ]]; then
        echo "  Uninstall suricata"
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
    if apt_install -o Dpkg::Options::="--force-overwrite" suricata; then

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

        echo "  Verify suricata config file /etc/suricata/suricata.yaml"
        suricata -T -c /etc/suricata/suricata.yaml || echo "Warning: Suricata config test returned warnings"

        # Enable and start service
        systemctl enable --now suricata.service || echo "Warning: service failed to start"

        # Verify Suricata is running in IDS mode
        systemctl status suricata --no-pager -l | head -n 20
        echo "  Suricata installed on interface: $PRIMARY_INTERFACE. Logs at /var/log/suricata/eve.json"
        echo "  To watch live what's going on, run:  tail -f /var/log/suricata/eve.json | jq"
    else
        echo "  [!] Suricata IDS installation failed — skipping configuration"
    fi
else
    echo "  Skipping Suricata IDS installation."
fi


echo ""
echo "--- 45. Install and configure Wazuh Agent ---"
if [[ "$INSTALL_WAZUHAGENT" =~ ^[Yy]$ ]]; then

    if [[ "$PROMPT_WAZUHAGENT" == 'reinstall' ]]; then
        echo "  Uninstall wazuh-agent"
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
            if apt_install wazuh-agent; then
                # Configure Manager Address
                sed -i "s/<address>MANAGER_IP<\/address>/<address>$WAZUH_MANAGER<\/address>/" /var/ossec/etc/ossec.conf
                systemctl enable --now wazuh-agent.service || echo "Warning: service failed to start"
            else
                echo "  [!] Wazuh Agent installation failed — skipping configuration"
            fi
        else
            echo "  [!] Could not download gpg key. Skipping installation."
        fi
    else
        echo "  No Wazuh Manager IP provided. Skipping installation."
    fi
else
    echo "  Skipping Wazuh Agent installation."
fi


echo ""
echo "--- 46. Configure AppArmor ---"
if [[ "$CONFIGURE_APPARMOR" =~ ^[Yy]$ ]]; then

    # Always ensure utilities and profiles are installed
    wait_for_apt
    if apt_install apparmor apparmor-utils apparmor-profiles apparmor-profiles-extra; then

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
                # hangs waiting for input: aa-genprof "$SERVICE_BIN" -f /dev/null 2>/dev/null || true
                aa-complain "$SERVICE_BIN" 2>/dev/null \
                    && echo "  [~] $(basename $SERVICE_BIN): complain mode (run sudo aa-logprof after normal use)" \
                    || echo "  [!] $(basename $SERVICE_BIN): failed to set complain mode"
            done

            # Summary
            echo ""
            echo "  AppArmor status summary:"
            aa-status 2>/dev/null | grep -E "profiles are in enforce|profiles are in complain|processes are in enforce|processes are unconfined"
        else
            echo "  [!] AppArmor installation failed — skipping configuration"
        fi
    elif [[ "$APPARMOR_ENABLE" =~ ^[Yy]$ ]]; then
        echo "  Leaving profiles in complain mode."
        aa-status 2>/dev/null | grep -E "profiles are in enforce|profiles are in complain"
    fi
else
    echo "  Skipping AppArmor configuration."
fi

# Configure modulejail only after all services are running. Otherwise detecting unused modules will be wrong.
echo ""
echo "--- 47. Configure Modulejail kernel blocklist ---"
if [[ "${CONFIGURE_MODULEJAIL:-}" =~ ^[Yy]$ ]]; then

    # Dynamically fetch the latest tag name via the GitHub API
    MODULEJAIL_LATEST=$(curl -sSL https://api.github.com/repos/jnuyens/modulejail/releases/latest 2>/dev/null \
    | jq -r .tag_name 2>/dev/null \
    | sed 's/v//' || true)

    if [[ -z "$MODULEJAIL_LATEST" ]]; then
        echo "  [!] Warning: could not determine latest modulejail version — using fallback $MODULEJAIL_FALLBACK_VERSION"
        MODULEJAIL_LATEST="$MODULEJAIL_FALLBACK_VERSION"
    fi

    echo "  Downloading modulejail script v${MODULEJAIL_LATEST} ..."
    curl -fsSL https://raw.githubusercontent.com/jnuyens/modulejail/v${MODULEJAIL_LATEST}/modulejail -o /tmp/modulejail || true
    if [[ -f "/tmp/modulejail" ]]; then

        # Create a whitelist in case modulejail is installed in a separate run before other networking services
        echo "  Creating module whitelist for networking, firewall, and IDS at /etc/modprobe.d/modulejail-whitelist.conf"
        rm -f /etc/modulejail/whitelist.conf || true
        install -d -m 0755 /etc/modulejail || true
        cat << EOF > /etc/modulejail/whitelist.conf
# Netfilter and Firewall Core
ip_tables
iptable_filter
nf_tables
nfnetlink
x_tables

# Fail2Ban and IP Sets
ip_set
ip_set_hash_ip
ip_set_hash_net

# Suricata IDS Packet Capture
af_packet
nfnetlink_queue
nf_conntrack
EOF
        chmod 0644 /etc/modulejail/whitelist.conf || true

        echo "  Running modulejail script to jail unused modules..."
        rm -f /etc/modprobe.d/modulejail-blacklist.conf || true
        sh /tmp/modulejail || true

        if [[ -f "/etc/modprobe.d/modulejail-blacklist.conf" ]]; then
            echo "  [V] Success. To revert: sudo rm /etc/modprobe.d/modulejail-blacklist.conf "
        else
            echo "  [!] No modules jailed"
        fi
    else
        echo "  [!] modulejail download failed"
    fi
else
    echo "  Skipping modulejail."
fi

echo ""
echo "--- 48. Install configuration files ---"

if [[ "$ANY_INSTALL_SET" =~ ^[Yy]$ ]]; then
    # Re-detect installed services now that installation is complete.
    # This updates ISINSTALLED_ variables to include services installed during this run,
    # so config files, Monit links, and restarts apply to all currently installed services.
    sleep 2
    echo "  Detecting installed services (post-install):"
    check_service_installed nginx PROMPT_NGINX ISINSTALLED_NGINX
    check_service_installed valkey-server PROMPT_VALKEY ISINSTALLED_VALKEY
    check_service_installed mysql PROMPT_MYSQL ISINSTALLED_MYSQL
    check_service_installed mariadb PROMPT_MARIADB ISINSTALLED_MARIADB
    check_service_installed postgresql PROMPT_POSTGRESQL ISINSTALLED_POSTGRESQL
    check_service_installed mosquitto PROMPT_MOSQUITTO ISINSTALLED_MOSQUITTO
    check_service_installed postfix PROMPT_POSTFIX ISINSTALLED_POSTFIX
    check_service_installed monit PROMPT_MONIT ISINSTALLED_MONIT
    check_service_installed webmin PROMPT_WEBMIN ISINSTALLED_WEBMIN
    check_service_installed grafana-server PROMPT_GRAFANA ISINSTALLED_GRAFANA
    check_service_installed forgejo PROMPT_FORGEJO ISINSTALLED_FORGEJO
    check_service_installed fail2ban PROMPT_FAIL2BAN ISINSTALLED_FAIL2BAN
    check_service_installed auditd PROMPT_AUDITD ISINSTALLED_AUDITD
    check_service_installed suricata PROMPT_SURICATA ISINSTALLED_SURICATA
    check_service_installed wazuh-agent PROMPT_WAZUHAGENT ISINSTALLED_WAZUHAGENT
    check_service_installed wazuh-manager PROMPT_WAZUHMANAGER ISINSTALLED_WAZUHMANAGER


    if [[ "$INSTALL_MYSQL" =~ ^[Yy]$ && "$ISINSTALLED_MYSQL" == "y" ]]; then
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
            # /etc/security/limits.d/ changes only apply to PAM-authenticated sessions. Services managed by systemd use their own LimitNOFILE directives in their unit files.
            mkdir -p /etc/systemd/system/mysql.service.d
            cp $CONFIG_DIR/etc/systemd/system/mysql.service.d/override.conf /etc/systemd/system/mysql.service.d/override.conf
        fi
    fi

    if [[ "$INSTALL_MARIADB" =~ ^[Yy]$ && "$ISINSTALLED_MARIADB" == "y" ]]; then
        echo "  Copying MariaDB config files"
        # MariaDB uses the same template as MySQL — reuse mysqld.cnf with same placeholders
        if [[ -f $CONFIG_DIR/etc/mysql/mariadb.conf.d/50-server.cnf ]]; then
            mkdir -p /etc/mysql/mariadb.conf.d/
            cp $CONFIG_DIR/etc/mysql/mariadb.conf.d/50-server.cnf /etc/mysql/mariadb.conf.d/50-server.cnf

            sed -i "s|%%INNODB_BUFFER_POOL_SIZE%%|${MYSQL_BUFFER_POOL_MB}M|g"            /etc/mysql/mariadb.conf.d/50-server.cnf
            sed -i "s|%%INNODB_BUFFER_POOL_INSTANCES%%|${MYSQL_BUFFER_POOL_INSTANCES}|g"  /etc/mysql/mariadb.conf.d/50-server.cnf
            sed -i "s|%%INNODB_BUFFER_POOL_CHUNK_SIZE%%|${MYSQL_BUFFER_POOL_CHUNK_MB}M|g" /etc/mysql/mariadb.conf.d/50-server.cnf
            sed -i "s|%%MAX_CONNECTIONS%%|${MYSQL_MAX_CONNECTIONS}|g"                    /etc/mysql/mariadb.conf.d/50-server.cnf
            sed -i "s|%%INNODB_LOG_BUFFER_SIZE%%|${MYSQL_LOG_BUFFER_MB}M|g"              /etc/mysql/mariadb.conf.d/50-server.cnf
            sed -i "s|%%BINLOG_CACHE_SIZE%%|${MYSQL_BINLOG_CACHE_MB}M|g"                 /etc/mysql/mariadb.conf.d/50-server.cnf
            sed -i "s|%%JOIN_BUFFER_SIZE%%|${MYSQL_JOIN_BUFFER_KB}K|g"                   /etc/mysql/mariadb.conf.d/50-server.cnf
            sed -i "s|%%SORT_BUFFER_SIZE%%|${MYSQL_SORT_BUFFER_KB}K|g"                   /etc/mysql/mariadb.conf.d/50-server.cnf
            sed -i "s|%%READ_BUFFER_SIZE%%|${MYSQL_READ_BUFFER_KB}K|g"                   /etc/mysql/mariadb.conf.d/50-server.cnf
            sed -i "s|%%READ_RND_BUFFER_SIZE%%|${MYSQL_READ_RND_BUFFER_KB}K|g"           /etc/mysql/mariadb.conf.d/50-server.cnf
        fi
    fi

    if [[ "$INSTALL_NGINX" =~ ^[Yy]$ && "$ISINSTALLED_NGINX" == "y" ]]; then
        echo "  Copying Nginx config files"
        if [[ -f $CONFIG_DIR/etc/nginx/nginx.conf ]]; then
            cp $CONFIG_DIR/etc/nginx/nginx.conf /etc/nginx/nginx.conf
            NGINX_WORKER_PROCESSES=${NGINX_WORKER_PROCESSES:-$PROCESSOR_COUNT}
            NGINX_CLIENT_BODY_MAX_SIZE=${NGINX_CLIENT_BODY_MAX_SIZE:-20M}
            sed -i "s|%%NGINX_WORKER_PROCESSES%%|$NGINX_WORKER_PROCESSES|g" /etc/nginx/nginx.conf
            sed -i "s|%%NGINX_CLIENT_BODY_MAX_SIZE%%|$NGINX_CLIENT_BODY_MAX_SIZE|g" /etc/nginx/nginx.conf
        fi

        if [[ -f $CONFIG_DIR/etc/nginx/sites-available/default ]]; then
            cp $CONFIG_DIR/etc/nginx/sites-available/default /etc/nginx/sites-available/default
        fi

        if [[ -f $CONFIG_DIR/etc/systemd/system/nginx.service.d/override.conf ]]; then
            # /etc/security/limits.d/ changes only apply to PAM-authenticated sessions. Services managed by systemd use their own LimitNOFILE directives in their unit files.
            mkdir -p /etc/systemd/system/nginx.service.d
            cp $CONFIG_DIR/etc/systemd/system/nginx.service.d/override.conf /etc/systemd/system/nginx.service.d/override.conf
        fi

        echo "  Testing nginx configuration"
        nginx -T || true
    fi

    if [[ "$INSTALL_VALKEY" =~ ^[Yy]$ && "$ISINSTALLED_VALKEY" == "y" ]]; then
        echo "  Copying Valkey config files"
        if [[ -f $CONFIG_DIR/etc/valkey/valkey.conf ]]; then
            cp $CONFIG_DIR/etc/valkey/valkey.conf /etc/valkey/valkey.conf
        fi
    fi

    if [[ "$INSTALL_POSTGRESQL" =~ ^[Yy]$ && "$ISINSTALLED_POSTGRESQL" == "y" ]]; then
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
            # /etc/security/limits.d/ changes only apply to PAM-authenticated sessions. Services managed by systemd use their own LimitNOFILE directives in their unit files.
            mkdir -p /etc/systemd/system/postgresql.service.d
            cp $CONFIG_DIR/etc/systemd/system/postgresql.service.d/override.conf /etc/systemd/system/postgresql.service.d/override.conf
        fi

        # Set superuser password (PostgreSQL must be running)
        echo "  Setting PostgreSQL superuser password..."
        PG_PASSWORD_ESCAPED=$(printf "%s" "$PG_PASSWORD" | sed "s/'/''/g")
        sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '${PG_PASSWORD_ESCAPED}';" || true
    fi

    if [[ "$INSTALL_GRAFANA" =~ ^[Yy]$ && "$ISINSTALLED_GRAFANA" == "y" ]]; then
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

    if [[ "$INSTALL_FORGEJO" =~ ^[Yy]$ && "$ISINSTALLED_FORGEJO" == "y" ]]; then
        echo "  Copying Forgejo config files"
        if [[ -f $CONFIG_DIR/etc/forgejo/app.ini ]]; then
            cp $CONFIG_DIR/etc/forgejo/app.ini /etc/forgejo/app.ini

            # Generate a random secret key for this installation
            FORGEJO_SECRET_KEY=$(openssl rand -hex 32)

            sed -i "s|%%FORGEJO_DOMAIN%%|$FORGEJO_DOMAIN|g"             /etc/forgejo/app.ini
            sed -i "s|%%FORGEJO_PORT%%|$FORGEJO_PORT|g"                 /etc/forgejo/app.ini
            sed -i "s|%%FORGEJO_SECRET_KEY%%|$FORGEJO_SECRET_KEY|g"     /etc/forgejo/app.ini
            sed -i "s|%%FORGEJO_DB_TYPE%%|$FORGEJO_DB_TYPE|g"           /etc/forgejo/app.ini
            sed -i "s|%%FORGEJO_DB_HOST%%|$FORGEJO_DB_HOST|g"           /etc/forgejo/app.ini
            sed -i "s|%%FORGEJO_DB_NAME%%|$FORGEJO_DB_NAME|g"           /etc/forgejo/app.ini
            sed -i "s|%%FORGEJO_DB_USER%%|$FORGEJO_DB_USER|g"           /etc/forgejo/app.ini
            sed -i "s|%%FORGEJO_DB_PASSWORD%%|$FORGEJO_DB_PASSWORD|g"   /etc/forgejo/app.ini
            sed -i "s|%%FORGEJO_MAILER_ENABLED%%|$FORGEJO_MAILER_ENABLED|g" /etc/forgejo/app.ini
            sed -i "s|%%FORGEJO_SMTP_ADDR%%|$FORGEJO_SMTP_ADDR|g"           /etc/forgejo/app.ini
            sed -i "s|%%FORGEJO_SMTP_PORT%%|$FORGEJO_SMTP_PORT|g"           /etc/forgejo/app.ini
            sed -i "s|%%FORGEJO_SMTP_PROTOCOL%%|$FORGEJO_SMTP_PROTOCOL|g"   /etc/forgejo/app.ini
            sed -i "s|%%FORGEJO_SMTP_FROM%%|$FORGEJO_SMTP_FROM|g"           /etc/forgejo/app.ini
            sed -i "s|%%FORGEJO_SMTP_USER%%|$FORGEJO_SMTP_USER|g"           /etc/forgejo/app.ini
            sed -i "s|%%FORGEJO_SMTP_PASSWORD%%|$FORGEJO_SMTP_PASSWORD|g"   /etc/forgejo/app.ini

            # make app.ini writeable for Forgejo so that it can update the configuration
            chown git:git /etc/forgejo/app.ini || true
            chmod 640 /etc/forgejo/app.ini || true

            # Restart Forgejo to pick up new config, wait for it to be ready
            echo "  Starting Forgejo..."
            systemctl restart forgejo || true
            FORGEJO_READY=0
            for i in {1..30}; do
                if curl -s -o /dev/null -4 --max-time 2 "http://127.0.0.1:${FORGEJO_PORT}" 2>/dev/null; then
                    FORGEJO_READY=1
                    break
                fi
                sleep 2
            done

            if [[ "$FORGEJO_READY" -eq 1 ]]; then
                echo "  [V] Forgejo is responding — creating admin user..."
                sudo -u git forgejo admin user create \
                    --username "$FORGEJO_ADMIN_USERNAME" \
                    --password "$FORGEJO_ADMIN_PASSWORD" \
                    --email "$FORGEJO_ADMIN_EMAIL" \
                    --admin \
                    --must-change-password=false \
                    --config /etc/forgejo/app.ini 2>/dev/null \
                    && echo "  [V] Admin user created: $FORGEJO_ADMIN_USERNAME" \
                    || echo "  [!] Could not create admin user — may already exist"
            else
                echo "  [!] Forgejo did not respond within 60s — skipping admin user creation"
                echo "      Run manually: sudo -u git forgejo admin user create --username admin --password <pwd> --email <email> --admin"
            fi
        fi
    fi

    if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ && "$ISINSTALLED_POSTFIX" == "y" ]]; then
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

        # Set mail headers to UTC timestamps. In case system time is not UTC.
        mkdir -p /etc/systemd/system/postfix.service.d
        cat << EOF > /etc/systemd/system/postfix.service.d/timezone.conf
[Service]
Environment=TZ=UTC
EOF

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

    if [[ "$INSTALL_MONIT" =~ ^[Yy]$ && "$ISINSTALLED_MONIT" == "y" ]]; then
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
            "$( [[ "$ISINSTALLED_MARIADB"    == "y" ]] && echo mariadb )" \
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
                cp -f "$SRC" "$DEST"
                # Substitute version-specific paths
                if [[ "$SERVICE" == "postgresql" ]]; then
                    sed -i "s|%%PG_VERSION%%|$PG_VERSION|g" "$DEST"
                fi
                rm -f "$LINK"
                ln -s "$DEST" /etc/monit/conf-enabled/
            else
                echo "  Warning: Monit config not found for $SERVICE, skipping."
            fi
        done

        # Link remaining utilities
        for UTILITY in "reboot-required" "disk-alerts"; do
            SRC="$CONFIG_DIR/etc/monit/conf-available/$UTILITY"
            DEST="/etc/monit/conf-available/$UTILITY"
            LINK="/etc/monit/conf-enabled/$UTILITY"
            [[ ! -f "$SRC" ]] && continue
            [[ -L "$LINK" ]] && continue
            cp -f "$SRC" "$DEST"
            ln -s "$DEST" /etc/monit/conf-enabled/
        done

        # Remove conf-enabled links for services that are no longer installed
        declare -A SERVICE_VAR_MAP=(
            ["mysql"]="ISINSTALLED_MYSQL"
            ["mariadb"]="ISINSTALLED_MARIADB"
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


    # Wazuh Agent log monitoring configuration
    if [[ "$INSTALL_WAZUHAGENT" =~ ^[Yy]$ && "$ISINSTALLED_WAZUHAGENT" == "y" && -f /var/ossec/etc/ossec.conf ]]; then
        echo "  Configuring Wazuh log monitoring..."

        append_localfile_to_ossec() {
            local guard="$1"
            local xml="$2"
            if ! grep -qF "$guard" /var/ossec/etc/ossec.conf; then
                printf "\n<ossec_config>\n%s\n</ossec_config>\n" "$xml" \
                    >> /var/ossec/etc/ossec.conf
                echo "  [+] Added log monitor: $guard"
            else
                echo "  [=] Already present: $guard"
            fi
        }

        append_localfile_to_ossec "/var/log/syslog" \
    '  <localfile>
        <log_format>syslog</log_format>
        <location>/var/log/syslog</location>
      </localfile>'

        if [[ "$ISINSTALLED_AUDITD" == "y" ]]; then
            append_localfile_to_ossec "/var/log/audit/audit.log" \
    '  <localfile>
        <log_format>audit</log_format>
        <location>/var/log/audit/audit.log</location>
      </localfile>'
        fi

        if [[ "$ISINSTALLED_NGINX" == "y" ]]; then
            append_localfile_to_ossec "/var/log/nginx/access.log" \
    '  <localfile>
        <log_format>apache</log_format>
        <location>/var/log/nginx/access.log</location>
      </localfile>
      <localfile>
        <log_format>apache</log_format>
        <location>/var/log/nginx/error.log</location>
      </localfile>'
        fi

        if [[ "$ISINSTALLED_MYSQL" == "y" || "$ISINSTALLED_MARIADB" == "y" ]]; then
            append_localfile_to_ossec "/var/log/mysql/error.log" \
    '  <localfile>
        <log_format>mysql_log</log_format>
        <location>/var/log/mysql/error.log</location>
      </localfile>'
        fi

        if [[ "$ISINSTALLED_POSTGRESQL" == "y" ]]; then
            append_localfile_to_ossec "postgresql-${PG_VERSION}-main.log" \
    "  <localfile>
        <log_format>postgresql_log</log_format>
        <location>/var/log/postgresql/postgresql-${PG_VERSION}-main.log</location>
      </localfile>"
        fi

        if [[ "$ISINSTALLED_GRAFANA" == "y" ]]; then
            append_localfile_to_ossec "/var/log/grafana/grafana.log" \
    '  <localfile>
        <log_format>syslog</log_format>
        <location>/var/log/grafana/grafana.log</location>
      </localfile>'
        fi

        if [[ "$ISINSTALLED_FORGEJO" == "y" ]]; then
            append_localfile_to_ossec "/var/lib/forgejo/log/gitea.log" \
    '  <localfile>
        <log_format>syslog</log_format>
        <location>/var/lib/forgejo/log/gitea.log</location>
      </localfile>
      <localfile>
        <log_format>syslog</log_format>
        <location>/var/lib/forgejo/log/access.log</location>
      </localfile>'
        fi

        if [[ "$ISINSTALLED_SURICATA" == "y" ]]; then
            append_localfile_to_ossec "/var/log/suricata/eve.json" \
    '  <localfile>
        <log_format>json</log_format>
        <location>/var/log/suricata/eve.json</location>
      </localfile>'
        fi

        if [[ "$ISINSTALLED_POSTFIX" == "y" ]]; then
            append_localfile_to_ossec "/var/log/mail.log" \
    '  <localfile>
        <log_format>syslog</log_format>
        <location>/var/log/mail.log</location>
      </localfile>'
        fi

        echo "  Wazuh log monitoring configured."
    fi
    
    # Wazuh-Agent self-monitoring adjustment for server running Wazuh-Manager
    if [[ "$INSTALL_WAZUHAGENT" =~ ^[Yy]$ && "$ISINSTALLED_WAZUHAGENT" == "y" && -f /var/ossec/etc/ossec.conf ]]; then
        if [[ "$INSTALL_WAZUHMANAGER" =~ ^[Yy]$ || "$ISINSTALLED_WAZUHMANAGER" == "y" ]]; then
            echo "  [Wazuh] Manager detected — adjusting agent for local self-monitoring ..."
    
            # Point agent to localhost instead of external manager IP
            sed -i 's|<address>.*</address>|<address>127.0.0.1</address>|' \
                /var/ossec/etc/ossec.conf
    
            # Add syscheck exclusions and monitors (idempotent)
            if ! grep -qF 'Exclude noisy Wazuh runtime directories' /var/ossec/etc/ossec.conf; then
                sed -i '/<\/syscheck>/i \
        <!-- Exclude noisy Wazuh runtime directories -->\
        <ignore>/var/ossec/queue</ignore>\
        <ignore>/var/ossec/logs</ignore>\
        <ignore>/var/ossec/stats</ignore>\
        <ignore>/var/ossec/var</ignore>\
        <ignore>/var/ossec/tmp</ignore>\
        <!-- Monitor sensitive Wazuh config and binaries -->\
        <directories check_all="yes" realtime="yes">/var/ossec/etc</directories>\
        <directories check_all="yes" realtime="yes">/var/ossec/bin</directories>\
        <directories check_all="yes" realtime="yes">/var/ossec/active-response</directories>' \
                    /var/ossec/etc/ossec.conf
                echo "  [+] Wazuh syscheck exclusions and monitors added"
            else
                echo "  [=] Wazuh syscheck config already present"
            fi
    
            # Restart agent after config changes (manager must already be running)
            systemctl restart wazuh-agent || echo "  [!] Warning: wazuh-agent restart failed"
            echo "  [V] Wazuh agent configured for manager self-monitoring"
        fi
    fi    


    # Restart services to apply new configs
    echo "  Restarting services to apply configs"
    [[ "$ISINSTALLED_MYSQL" == "y" ]]      && systemctl restart mysql           || true
    [[ "$ISINSTALLED_MARIADB" == "y" ]]    && systemctl restart mariadb         || true
    [[ "$ISINSTALLED_NGINX" == "y" ]]      && systemctl restart nginx           || true
    [[ "$ISINSTALLED_VALKEY" == "y" ]]     && systemctl restart valkey-server   || true
    [[ "$ISINSTALLED_POSTGRESQL" == "y" ]] && systemctl restart postgresql      || true
    [[ "$ISINSTALLED_POSTFIX" == "y" ]]    && systemctl restart postfix         || true
    [[ "$ISINSTALLED_GRAFANA" == "y" ]]    && systemctl restart grafana-server  || true
    [[ "$ISINSTALLED_FORGEJO" == "y" ]]    && systemctl restart forgejo         || true
    [[ "$ISINSTALLED_MOSQUITTO" == "y" ]]  && systemctl restart mosquitto       || true
    [[ "$ISINSTALLED_MONIT" == "y" ]]      && systemctl restart monit           || true
    [[ "$ISINSTALLED_WAZUHAGENT" == "y" ]] && systemctl restart wazuh-agent     || true
    sleep 2
    echo "  Services restarted"

    echo "  Configuration files installed."

else
    echo "  Skipping configuration files"
fi

echo ""
echo "--- 49. Finalise installation ---"

if [[ "$ANY_INSTALL_SET" =~ ^[Yy]$ ]]; then
    sysctl --system

    apt-get --fix-broken install || true
    # Cleanup leftover config packages
    # apt-get autoremove -y ; apt-get -y purge $(dpkg --list | grep ^rc | awk '{ print $2; }')
    mapfile -t RC_PACKAGES < <(dpkg --list | awk '/^rc/ {print $2}')
    if [ ${#RC_PACKAGES[@]} -gt 0 ]; then
        echo "  Purging leftover configuration packages: ${RC_PACKAGES[*]}"
        apt-get purge -y "${RC_PACKAGES[@]}" || true
    else
        echo "  No leftover config packages found."
    fi
    apt-get -y autoremove || true

    echo "  Restarting unattended upgrades"
    restart_autoupdate
else
    echo "  Skipping finalising"
fi


echo ""
echo "--- 50. Generating Health Check Script ---"

if [[ "$CREATE_HEALTHSCRIPT" =~ ^[Yy]$ ]]; then
    HEALTH_CHECK_SCRIPT="/home/$USER_SUDO_USER_USERNAME/ubuntu_health_check.sh"
    # We start the file with the header and basic checks.
    # use 'EOF' to tell bash not to expand variables (e.g. 1, 2, GREEN)
    cat <<'EOF' > $HEALTH_CHECK_SCRIPT
#!/bin/bash
# UBUNTU 24.04 and 26.04 SERVER HEALTH CHECK SCRIPT
# by Xlvisuals Limited

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREY='\033[0;37m'
NC='\033[0m'

# --- Function to check service status ---
check_service_status() {
    local service="$1"
    local name="$2"
    local units
    units=$(systemctl list-unit-files "${service}.service" 2>/dev/null) || true
    if ! echo "$units" | grep -q "${service}.service"; then
        echo -e "$name: ${GREY}[NOT INSTALLED]${NC}"
    elif systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "$name: ${GREEN}[RUNNING]${NC}"
    elif systemctl is-failed --quiet "$service" 2>/dev/null; then
        echo -e "$name: ${RED}[FAILED]${NC}"
    else
        echo -e "$name: ${YELLOW}[STOPPED]${NC}"
    fi
}


echo "==========================================="
echo "      XLVISUALS SERVER HEALTH CHECK "
echo "==========================================="

echo ""
echo "SSH config"
echo "==========================================="
# sudo sshd -T | egrep -i 'UsePAM|PermitRootLogin|ChallengeResponseAuthentication|PasswordAuthentication|PermitEmptyPasswords|MaxStartups|LoginGraceTime|MaxAuthTries|PubkeyAuthentication|AllowUsers|ClientAliveCountMax|MaxSessions|AllowTcpForwarding|TCPKeepAlive|X11Forwarding|IgnoreRhosts|AuthenticationMethods|PrintMotd'
# Fetch the active runtime configuration from sshd
sudo sshd -T | egrep -i 'UsePAM|PermitRootLogin|ChallengeResponseAuthentication|PasswordAuthentication|PermitEmptyPasswords|MaxStartups|LoginGraceTime|MaxAuthTries|PubkeyAuthentication|AllowUsers|ClientAliveCountMax|MaxSessions|AllowTcpForwarding|TCPKeepAlive|X11Forwarding|IgnoreRhosts|AuthenticationMethods|PrintMotd' | \
while read -r param value; do
    # Normalize parameter name to lowercase for easy matching
    param_lower=$(echo "$param" | tr '[:upper:]' '[:lower:]')
    is_safe=false

    case "$param_lower" in
        # These parameters should strictly be "no"
        permitrootlogin|passwordauthentication|challengeresponseauthentication|permitemptypasswords|x11forwarding|ignorerhosts)
            if [ "$value" = "no" ]; then is_safe=true; fi
            ;;
        # These parameters should strictly be "yes"
        usepam|pubkeyauthentication|tcpkeepalive|printmotd)
            if [ "$value" = "yes" ]; then is_safe=true; fi
            ;;
        # MaxAuthTries should be 4 or fewer
        maxauthtries)
            if [ "$value" -le 4 ]; then is_safe=true; fi
            ;;
        # LogingGraceTime should be 60 seconds or fewer
        logingracetime)
            if [ "$value" -le 60 ]; then is_safe=true; fi
            ;;
        # MaxSessions should be restricted (e.g., 10 or fewer)
        maxsessions)
            if [ "$value" -le 10 ]; then is_safe=true; fi
            ;;
        # ClientAliveCountMax should be low (e.g., 2 or fewer)
        clientalivecountmax)
            if [ "$value" -le 2 ]; then is_safe=true; fi
            ;;
        # Pass-through rules: parameters that vary wildly by environment (like AllowUsers, MaxStartups, AllowTcpForwarding)
        # We default them to green if they exist, or you can customize their rules below
        allowusers|maxstartups|allowtcpforwarding|authenticationmethods)
            is_safe=true
            ;;
    esac

    # Print the result with the evaluated color
    if [ "$is_safe" = true ]; then
        echo -e "${param} ${value} -> ${GREEN}[OK]${NC}"
    else
        echo -e "${param} ${value} -> ${RED}[WARNING]${NC}"
    fi
done

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
echo "Vulnerable Kernel Modules (Page-Cache Exploits)"
echo "==========================================="
# Test if modprobe evaluates these modules to /bin/false
for module in algif_aead af_alg esp4 esp6 rxrpc; do
    status=$(modprobe -n -v "$module" 2>&1)
    if echo "$status" | grep -q "install /bin/false"; then
        echo -e "${module}: ${GREEN}[BLOCKED]${NC}"
    else
        echo -e "${module}: ${RED}[VULNERABLE / ALLOWED]${NC}"
    fi
done

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
check_service_status "nginx" "NGINX Web Server"
check_service_status "valkey-server" "Valkey Server"
check_service_status "mysql" "MySQL Server"
check_service_status "mariadb" "MariaDB Server"
check_service_status "postgresql" "PostgreSQL Server"
check_service_status "mosquitto" "Mosquitto Broker"
check_service_status "monit" "Monit Server"
check_service_status "webmin" "Webmin Server"
check_service_status "grafana-server" "Grafana Server"
check_service_status "forgejo" "Forgejo Git Server"
check_service_status "fail2ban" "Fail2Ban IDS"
check_service_status "auditd" "Auditd Daemon"
check_service_status "suricata" "Suricata IDS"
check_service_status "wazuh-agent" "Wazuh Agent"
check_service_status "postfix" "Postfix Mail Relay"

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
        check_apparmor "MariaDB"        "/usr/sbin/mariadbd" "mariadb"
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
echo "IP Blocklist"
echo "==========================================="
if [[ -n "$(sudo ipset list -n 2>/dev/null | grep ufw-blocklist-ipsum)" ]]; then
    UPDATED=$(grep "finished updating ufw-blocklist-ipsum" /var/log/syslog 2>/dev/null | tail -1 | awk '{print $1}' | sed 's/T/ /' | cut -d. -f1)
    # Get last update time from syslog
    UPDATED=$(grep "finished updating ufw-blocklist-ipsum" /var/log/syslog 2>/dev/null | tail -1 | awk '{print $1}')
    echo -e "  Blocked IPs  : ${COUNT:-unknown}"
    echo -e "  Last updated : ${UPDATED:-unknown}"
else
    echo -e "  ${RED}[NOT ACTIVE]${NC}"
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
    echo "  None"
fi

echo ""
echo "Port usage"
echo "==========================================="
ufw_status() {
    local port="$1"
    if [ "$(ufw status)" = "Status: inactive" ]; then
        echo "${RED}[ALLOWED (UFW inactive)]${NC}"
    elif ufw status | grep -qE "^${port}(/tcp)?\s+ALLOW"; then
        echo -e "${RED}[ALLOWED]${NC}"
    else
        echo -e "${GREEN}[BLOCKED]${NC}"
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
check_port "mariadb"        "3306"
check_port "postgresql"     "5432"
check_port "valkey-server"  "6379"
check_port "mosquitto"      "1883"
check_port "postfix"        "25"
check_port "monit"          "2812"
check_port "grafana-server" "3000"
check_port "forgejo"        "$(grep -oP '(?<=HTTP_PORT\s=\s)\d+' /etc/forgejo/app.ini 2>/dev/null || echo 3000)"
check_port "webmin"         "10000"

echo ""
echo "Smoke Tests"
echo "==========================================="

smoke_ok()   { echo -e "  ${GREEN}[V]${NC} $1"; }
smoke_warn() { echo -e "  ${RED}[!]${NC} $1"; }
smoke_skip() { echo "  [-] $1 (not installed)"; }

smoke_http() {
    local label="$1" url="$2" expected="$3" extra_args="${4:-}"
    local code
    # set -4 to use ipv4, since curl might use ipv6 otherwise which will fail for e.g. monit
    code=$(curl -s -o /dev/null -w "%{http_code}" -4 $extra_args --max-time 5 "$url" 2>/dev/null || true)
    if [[ -z "$code" || "$code" == "000" ]]; then
        smoke_warn "$label: could not connect — is the service running?"
    elif [[ "$code" == "$expected" || ( "$code" =~ ^(200|301|302|401|403)$ && "$expected" == "ok" ) ]]; then
        smoke_ok "$label: HTTP $code"
    else
        smoke_warn "$label: unexpected HTTP $code (expected $expected)"
    fi
}

# HTTP checks
if systemctl is-active --quiet nginx 2>/dev/null; then
    smoke_http "Nginx HTTP"  "http://localhost"  "ok"
    if [[ -f /etc/letsencrypt/live/*/fullchain.pem ]] || grep -qr "ssl_certificate" /etc/nginx/sites-enabled/ 2>/dev/null; then
        smoke_http "Nginx HTTPS" "https://localhost" "ok" "-k"
    else
        smoke_skip "Nginx HTTPS (no SSL certificate configured)"
    fi
else smoke_skip "Nginx"; fi

if systemctl is-active --quiet grafana-server 2>/dev/null; then
    smoke_http "Grafana" "http://localhost:3000" "ok"
else smoke_skip "Grafana"; fi

if systemctl is-active --quiet forgejo 2>/dev/null; then
    FORGEJO_HC_PORT=$(grep -oP '(?<=HTTP_PORT\s=\s)\d+' /etc/forgejo/app.ini 2>/dev/null || echo 3000)
    smoke_http "Forgejo" "http://localhost:${FORGEJO_HC_PORT}" "ok"
else smoke_skip "Forgejo"; fi

if systemctl is-active --quiet monit 2>/dev/null; then
    smoke_http "Monit" "http://localhost:2812" "401"
else smoke_skip "Monit"; fi

if systemctl is-active --quiet webmin 2>/dev/null; then
    smoke_http "Webmin" "https://localhost:10000" "ok" "-k"
else smoke_skip "Webmin"; fi

# Database checks
if systemctl is-active --quiet mysql 2>/dev/null; then
    if mysql -u healthcheck -e "SELECT 1;" &>/dev/null; then
        smoke_ok "MySQL: connection OK"
    else
        smoke_warn "MySQL: connection failed — check service status"
    fi
else smoke_skip "MySQL"; fi

if systemctl is-active --quiet mariadb 2>/dev/null; then
    if mysql -u healthcheck -e "SELECT 1;" &>/dev/null; then
        smoke_ok "MariaDB: connection OK"
    else
        smoke_warn "MariaDB: connection failed — check service status"
    fi
else smoke_skip "MariaDB"; fi

if systemctl is-active --quiet postgresql 2>/dev/null; then
    if sudo -u postgres psql -c "SELECT 1;" &>/dev/null; then
        smoke_ok "PostgreSQL: connection OK"
    else
        smoke_warn "PostgreSQL: connection failed — check service status"
    fi
else smoke_skip "PostgreSQL"; fi

if systemctl is-active --quiet valkey-server 2>/dev/null; then
    if valkey-cli ping 2>/dev/null | grep -q "PONG"; then
        smoke_ok "Valkey: PONG received"
    else
        smoke_warn "Valkey: no PONG — check service status"
    fi
else smoke_skip "Valkey"; fi

if systemctl is-active --quiet mosquitto 2>/dev/null; then
    TMPFILE=$(mktemp)
    mosquitto_sub -t "_smoke_test" -C 1 -W 3 > "$TMPFILE" 2>/dev/null &
    MSUB_PID=$!
    sleep 0.3
    mosquitto_pub -t "_smoke_test" -m "ok" -q 0 2>/dev/null || true
    wait $MSUB_PID || true
    MSG=$(cat "$TMPFILE")
    rm -f "$TMPFILE"
    if [[ "$MSG" == "ok" ]]; then
        smoke_ok "Mosquitto: pub/sub OK"
    else
        smoke_warn "Mosquitto: pub/sub failed — check service status"
    fi
else smoke_skip "Mosquitto"; fi

echo ""
EOF
    echo "  Script $HEALTH_CHECK_SCRIPT created"

    chown $USER_SUDO_USER_USERNAME:$USER_SUDO_USER_USERNAME $HEALTH_CHECK_SCRIPT
    chmod +x $HEALTH_CHECK_SCRIPT

    echo "  Running $HEALTH_CHECK_SCRIPT ..."
    echo ""
    # Run health check
    $HEALTH_CHECK_SCRIPT
else
    echo "  Skipping Health Check script"
fi


echo ""
echo "--- 51. Postfix Test ---"

# HTTP, database, Valkey and Mosquitto tests are in the health check script.
# Only the Postfix test email runs here since we don't want it firing on every health check.
if [[ "$INSTALL_POSTFIX" =~ ^[Yy]$ && "$ISINSTALLED_POSTFIX" == "y" ]]; then
    echo ""
    echo "  Sending Postfix test mail to $POSTFIX_ROOT_ALIAS..."
    echo "Postfix test mail from $(hostname) after provisioning." \
        | mail -s "Postfix Test - $(hostname)" "$POSTFIX_ROOT_ALIAS" \
        && echo "  [V] Test mail sent to $POSTFIX_ROOT_ALIAS." \
        || echo "  [!] Test mail failed — check: sudo tail -n 20 /var/log/mail.log"
else
    echo "  Skipping Postfix test email."
fi


# Clear password variables
unset MYSQL_PASSWORD
unset MYSQL_PASSWORD_ESCAPED
unset PG_PASSWORD
unset PG_PASSWORD_ESCAPED
unset MONIT_MAILSERVER_PASSWORD
unset POSTFIX_RELAY_PASSWORD
unset GRAFANA_SMTP_PASSWORD
unset FORGEJO_SMTP_PASSWORD


echo ""
echo "--- 52. Setup Complete ---"

if [ ${#APT_PACKAGES_NOT_INSTALLED[@]} -ne 0 ]; then
    echo "Failed packages"
    echo "==========================================="
    echo "The following packages could NOT be installed"
    for PKG in "${APT_PACKAGES_NOT_INSTALLED[@]}"; do
        echo -e "  ${RED}[!]${NC} $PKG"
    done
    echo ""
fi


echo "  Logfile written to: $LOG_FILE"
echo "  Config backup written to current directory by ubuntu_backup_config.sh"

echo ""
echo "  SSH connect command with port forwards (localport:hostname:hostport):"
SSH_CMD="  ssh"
[[ "$ISINSTALLED_MOSQUITTO" =~ ^[Yy]$ ]]  && SSH_CMD="$SSH_CMD -L 11883:localhost:1883"
[[ "$ISINSTALLED_MONIT" =~ ^[Yy]$ ]]      && SSH_CMD="$SSH_CMD -L 12812:localhost:2812"
[[ "$ISINSTALLED_GRAFANA" =~ ^[Yy]$ ]]    && SSH_CMD="$SSH_CMD -L 13000:localhost:3000"
[[ "$ISINSTALLED_FORGEJO" =~ ^[Yy]$ ]]    && SSH_CMD="$SSH_CMD -L 1${FORGEJO_PORT}:localhost:${FORGEJO_PORT}"
[[ "$ISINSTALLED_MYSQL" =~ ^[Yy]$ ]]      && SSH_CMD="$SSH_CMD -L 13306:localhost:3306"
[[ "$ISINSTALLED_MARIADB" =~ ^[Yy]$ ]]    && SSH_CMD="$SSH_CMD -L 13306:localhost:3306"
[[ "$ISINSTALLED_POSTGRESQL" =~ ^[Yy]$ ]] && SSH_CMD="$SSH_CMD -L 15432:localhost:5432"
[[ "$ISINSTALLED_VALKEY" =~ ^[Yy]$ ]]     && SSH_CMD="$SSH_CMD -L 16379:localhost:6379"
[[ "$ISINSTALLED_WEBMIN" =~ ^[Yy]$ ]]     && SSH_CMD="$SSH_CMD -L 20000:localhost:10000"
SSH_CMD="$SSH_CMD $USER_SUDO_USER_USERNAME@$LOCAL_IP"
echo "$SSH_CMD"

if [[ "$CONFIGURE_APPARMOR" =~ ^[Yy]$ ]]; then
    echo ""
    echo "  AppArmor: nginx, postgresql, postfix, grafana set to complain mode."
    echo "  After normal use, run: sudo aa-logprof"
    echo "  Then to enforce: sudo aa-enforce /etc/apparmor.d/<profile>"
fi

echo ""
if [[ "$INSTALL_SSH" =~ ^[Yy]$ ]]; then
    echo "ACTION REQUIRED: Test SSH login in a NEW window before closing this one or you may be locked out."
fi

if [[ "$TUNE_SYSTEM" =~ ^[Yy]$ ]]; then
    echo "ACTION REQUIRED: Reboot the system to apply all changes."
fi