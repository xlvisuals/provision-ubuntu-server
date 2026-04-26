#!/bin/bash
#
# UBUNTU 24.04 and 26.04 SERVER PROVISIONING SCRIPT
# by Xlvisuals Limited 
# 26 April 2026
# -----------------------------------------------------------------------------------------
#
# PREREQUISITES:
#   - Ubuntu 24.04 or 26.04 Server, including "minimized" version
#   - Internet connection.
#   - requires 7GB disk space (+swap) for full installation on minimized server 
#   - requires 10GB disk space (+swap for full installation on standard server 
#
# INSTALLS (optional):
#   - Web Stack: Nginx, MySQL Server, PostgreSQL, Valkey.
#   - Management: Webmin, Monit, Grafana, Forgejo (Git).
#   - Runtimes: Python 3.14 (deadsnakes for 26.04), PyPy 3.11.
#   - Security: Fail2Ban, Suricata, auditd, Wazuh Agent.
#   - Tools: vim, nano, ne, micro, btop, ncdu, nmap, lynis, weasyprint, imagemagick.
#
# MODIFIES (optional):
#   - Security: Hardens SSH (Key-only), Configures UFW, Sets sysctl limits.
#   - Disk: Resizes LVM, Adds Swap file.
#   - Automation: Custom Unattended-Upgrades timers, Sudo timeout/NOPASSWD.
#   - User: Requires a sudo user. Offers to create new user and sets up SSH key access.


# Set package versions
PG_VERSION="18"
PYPY311_VERSION="pypy3.11-v7.3.21-linux64"

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

# change into current directory
cd "$(dirname "$(readlink -f "$0")")" || exit

# Exit when any command fails silently
set -Eeuo pipefail

# Easier debugging
trap 'echo "ERROR on line $LINENO"' ERR

# Prevents any apt prompts from breaking the script.
export DEBIAN_FRONTEND=noninteractive

# auto-confirm and faster installs
APT_FLAGS="-y -o Dpkg::Use-Pty=0"

# helper functions

check_service() {
    local service="$1"
    local var="$2"

    if systemctl status "$service" &>/dev/null; then
        echo "- $service is already installed"
        printf -v "$var" "reinstall"
    else
           echo "- $service is NOT installed"
        printf -v "$var" "install  "
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
        printf -v "$var" "install  "
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

# LOGGING SETUP
LOG_FILE="/var/log/ubuntu_provision_$(date +%F_%H%M%S).log"
# Use 'exec' to redirect STDOUT and STDERR through 'tee'
# This captures EVERYTHING that follows into the log file.
exec > >(tee -a "$LOG_FILE") 2>&1



echo "Xlvisuals Ubuntu LTS server provisioning"
echo "Provisioning started: $(date)"
echo "Logging to: $LOG_FILE"

echo "Stopping unattended upgrades"
systemctl stop apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer

# Detect network interface
# PRIMARY_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
# PRIMARY_INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
PRIMARY_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$PRIMARY_INTERFACE" ]; then
    echo "Error: Could not detect network interface"
    exit 1
fi
echo "Detected network interface: $PRIMARY_INTERFACE"

# Detect network IP, just for logging
PRIMARY_IP=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+')
echo "Detected network address: $PRIMARY_IP"

# Verify we have internet. Fails on Ubuntu minimized as no iputils-ping package
if command -v ping >/dev/null 2>&1; then
    ping -c 1 1.1.1.1 >/dev/null || {
        echo "Error: No internet connection"
        exit 1
    }
else
    echo "Warning: 'ping' command not found, skipping internet connectivity check."
fi


echo ""
echo "--- 1. Backup original configuration ---"
BACKUP_DIR="/root/original_config_backup_$(date +%F_%H%M%S)"
mkdir -p "$BACKUP_DIR"
# Define the list of files and directories to back up
PATHS_TO_BACKUP=("/etc/ssh" "/etc/apt" "/etc/sysctl.conf" "/etc/fstab" "/etc/security/limits.conf")

for item in "${PATHS_TO_BACKUP[@]}"; do
    if [ -e "$item" ]; then
        cp -r "$item" "$BACKUP_DIR/"
    else
        echo "Warning: $item not found, skipping."
    fi
done

echo "Configuration backups stored in $BACKUP_DIR"


echo ""
echo "--- 2. Localization  ---"
echo "Set timezone to UTC"
timedatectl set-timezone UTC


echo ""
echo "--- 3. Configure new installation ---" 

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
check_service nginx PROMPT_NGINX
check_service valkey PROMPT_VALKEY
check_service mysql PROMPT_MYSQL
check_service postgresql PROMPT_POSTGRESQL
check_service mosquitto PROMPT_MOSQUITTO
check_service monit PROMPT_MONIT
check_service webmin PROMPT_WEBMIN
check_service grafana-server PROMPT_GRAFANA
check_service forgejo PROMPT_FORGEJO
check_service fail2ban PROMPT_FAIL2BAN
check_service auditd PROMPT_AUDITD
check_service suricata PROMPT_SURICATA
check_service wazuh-agent PROMPT_WAZUH


if [[ -f /etc/cron.daily/ufw-blocklist-ipsum && -s /etc/cron.daily/ufw-blocklist-ipsum ]]; then
    echo "- IP blocklist is already installed"
    PROMPT_IPBLOCK='reinstall'
else
    PROMPT_IPBLOCK='install  '
fi

# Detect the calling user
REAL_USER=${SUDO_USER:-$(logname 2>/dev/null)}
MY_SUDO_USERNAME=""

echo ""
echo "Configure installation options:"
read -p "Would you like to add a new sudo user?     (y/n): " ADD_SUDO_USER
if [[ "$ADD_SUDO_USER" =~ ^[Yy]$ ]]; then
    # Interactive username host prompt
    while true; do
        read -p "                                 Enter username : " MY_SUDO_USERNAME
        echo
        if [[ ${#MY_SUDO_USERNAME} -ge 4 ]]; then
            break
        fi
    done
else
    # If run via sudo, offer the current user as the default
    if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
        read -p "Use current user '$REAL_USER' for setup?    (y/n): " USE_CURRENT
        if [[ "$USE_CURRENT" =~ ^[Yy]$ || -z "$USE_CURRENT" ]]; then
            MY_SUDO_USERNAME=$REAL_USER
        fi
    fi

    # Ask manually if not using sudo or not wanting current user
    if [[ -z "$MY_SUDO_USERNAME" ]]; then
        while true; do
            read -p "                   Enter existing sudo username : " MY_SUDO_USERNAME
            if [[ ${#MY_SUDO_USERNAME} -ge 4 ]]; then
                break
            fi
            echo "Username must be at least 4 characters."
        done
    fi
fi

# Final Check
if [[ -z "$MY_SUDO_USERNAME" ]]; then
    echo "Error: We need a sudo user to complete the setup."
    exit 1
fi

read -p "Would you like to configure LVM disks?     (y/n): " CONFIGURE_LVM
read -p "Would you like to configure swap space?    (y/n): " CONFIGURE_SWAP
read -p "Would you like to tune the system?         (y/n): " TUNE_SYSTEM
read -p "Would you like to uninstall packages?      (y/n): " UNINSTALL_PACKAGES
read -p "Would you like to update packages?         (y/n): " UPDATE_PACKAGES
read -p "Would you like to install new packages?    (y/n): " INSTALL_PACKAGES
read -p "Would you like to configure ufw?           (y/n): " INSTALL_UFW
read -p "Would you like to configure ssh?           (y/n): " INSTALL_SSH
read -p "Would you like to install fonts?           (y/n): " INSTALL_FONTS
read -p "Would you like to $PROMPT_WEASYPRINT weasyprint?    (y/n): " INSTALL_WEASYPRINT
read -p "Would you like to $PROMPT_IMAGEMAGICK imagemagick?   (y/n): " INSTALL_IMAGEMAGICK
read -p "Would you like to $PROMPT_CPYTHON314 Python 3.14?   (y/n): " INSTALL_CPYTHON314
read -p "Would you like to $PROMPT_PYPY311 Pypy 3.11?     (y/n): " INSTALL_PYPY311
read -p "Would you like to $PROMPT_NGINX nginx?         (y/n): " INSTALL_NGINX
read -p "Would you like to $PROMPT_VALKEY valkey?        (y/n): " INSTALL_VALKEY
read -p "Would you like to $PROMPT_MYSQL MySQL?         (y/n): " INSTALL_MYSQL
if [[ "$INSTALL_MYSQL" =~ ^[Yy]$ ]]; then
    # Interactive Password Prompt
    while true; do
        read -sp "  Enter MySQL root password   : " MYSQL_PASS
        echo
        read -sp "  Confirm MySQL root password : " MYSQL_PASS_CONFIRM
        echo
        # Check if passwords match AND length is at least 4
        if [ "$MYSQL_PASS" == "$MYSQL_PASS_CONFIRM" ] && [ "${#MYSQL_PASS}" -ge 4 ]; then
            break
        elif [ "${#MYSQL_PASS}" -lt 4 ]; then
            echo "Password is too short. Must be at least 4 characters."
        else
            echo "Passwords do not match. Please try again."
        fi
    done
    # escape for SQL, including ' " \ $
    MYSQL_PASS_ESCAPED=$(printf "%s" "$MYSQL_PASS" | sed "s/'/''/g")
else
    MYSQL_PASS=''
    MYSQL_PASS_CONFIRM=''
    MYSQL_PASS_ESCAPED=''
fi
read -p "Would you like to $PROMPT_POSTGRESQL PostgreSQL $PG_VERSION? (y/n): " INSTALL_POSTGRESQL
read -p "Would you like to $PROMPT_MOSQUITTO Mosquitto?     (y/n): " INSTALL_MOSQUITTO
read -p "Would you like to $PROMPT_MONIT Monit?         (y/n): " INSTALL_MONIT
read -p "Would you like to $PROMPT_WEBMIN Webmin?        (y/n): " INSTALL_WEBMIN
read -p "Would you like to $PROMPT_GRAFANA Grafana?       (y/n): " INSTALL_GRAFANA
read -p "Would you like to $PROMPT_FORGEJO Forgejo?       (y/n): " INSTALL_FORGEJO
read -p "Would you like to $PROMPT_FAIL2BAN Fail2Ban?      (y/n): " INSTALL_FAIL2BAN
read -p "Would you like to $PROMPT_AUDITD auditd?        (y/n): " INSTALL_AUDITD
read -p "Would you like to $PROMPT_IPBLOCK IP blocklist?  (y/n): " INSTALL_IPBLOCK
read -p "Would you like to $PROMPT_SURICATA Suricata IDS?  (y/n): " INSTALL_SURICATA
read -p "Would you like to $PROMPT_WAZUH Wazuh Agent?   (y/n): " INSTALL_WAZUH
if [[ "$INSTALL_WAZUH" =~ ^[Yy]$ ]]; then
    # Interactive Manager host prompt
    while true; do
        read -p "  Enter IP or Hostname of Wazuh Manager : " WAZUH_MANAGER
        echo
        if [[ ${#WAZUH_MANAGER} -ge 4 ]]; then
            break
        fi
    done
else
    WAZUH_MANAGER=''
fi


echo ""
echo "Configuration settings:"
echo "Add sudo user?           : $ADD_SUDO_USER"
if [[ "$ADD_SUDO_USER" =~ ^[Yy]$ ]]; then
  echo "            new username : $MY_SUDO_USERNAME"
else
  echo "       existing username : $MY_SUDO_USERNAME"
fi
echo "Configure LVM disks?     : $CONFIGURE_LVM"
echo "Configure swap space?    : $CONFIGURE_SWAP"
echo "Tune system?             : $TUNE_SYSTEM"
echo "Uninstall packages?      : $UNINSTALL_PACKAGES"
echo "Update packages?         : $UPDATE_PACKAGES"
echo "Install new packages?    : $INSTALL_PACKAGES"
echo "Install ufw?             : $INSTALL_UFW"
echo "Install ssh?             : $INSTALL_SSH"
echo "Install fonts?           : $INSTALL_FONTS"
echo "Install weasyprint?      : $INSTALL_WEASYPRINT"
echo "Install imagemagick?     : $INSTALL_IMAGEMAGICK"
echo "Install Python 3.14?     : $INSTALL_CPYTHON314"
echo "Install Pypy 3.11?       : $INSTALL_PYPY311"
echo "Install nginx?           : $INSTALL_NGINX"
echo "Install valkey?          : $INSTALL_VALKEY"
echo "Install MySQL?           : $INSTALL_MYSQL"
echo "Install Monit?           : $INSTALL_MONIT"
echo "Install Webmin?          : $INSTALL_WEBMIN"
echo "Install Grafana?         : $INSTALL_GRAFANA"
echo "Install Forgejo?         : $INSTALL_FORGEJO"
echo "Install Fail2Ban?        : $INSTALL_FAIL2BAN"
echo "Install auditd?          : $INSTALL_AUDITD"
echo "Install IP blocklist?    : $INSTALL_IPBLOCK"
echo "Install Suricata IDS?    : $INSTALL_SURICATA"
echo "Install Wazuh Agent?     : $INSTALL_WAZUH"
if [[ "$INSTALL_WAZUH" =~ ^[Yy]$ ]]; then
  echo "           Wazuh Manager : $WAZUH_MANAGER"
fi


echo ""
echo "--- 4. Create/update user ---"
if [[ "$ADD_SUDO_USER" =~ ^[Yy]$ ]]; then
    if ! id "$MY_SUDO_USERNAME" &>/dev/null; then
        echo "Creating user $MY_SUDO_USERNAME."
        adduser --gecos "" --disabled-password "$MY_SUDO_USERNAME"
        echo "Created user $MY_SUDO_USERNAME"
        echo ""
        echo "Setting system password for user: $MY_SUDO_USERNAME"
        passwd $MY_SUDO_USERNAME
        usermod -aG sudo $MY_SUDO_USERNAME
        usermod -a -G adm $MY_SUDO_USERNAME
        chmod 750 /home/$MY_SUDO_USERNAME
    else
        echo "User $MY_SUDO_USERNAME exists."
    fi
    echo "Adding user $MY_SUDO_USERNAME to groups sudo and adm"
    usermod -a -G sudo $MY_SUDO_USERNAME
    usermod -a -G adm $MY_SUDO_USERNAME
    echo "Updating home folder permissions."
    chmod 750 /home/$MY_SUDO_USERNAME    
else
    echo "Skipping new sudo user."
    echo "Adding user $MY_SUDO_USERNAME to groups sudo and adm"
    usermod -a -G sudo $MY_SUDO_USERNAME
    usermod -a -G adm $MY_SUDO_USERNAME
    echo "Updating home folder permissions."
    chmod 750 /home/$MY_SUDO_USERNAME        
fi

    
echo ""
echo "--- 5. Configure LVM disks ---"
if [[ "$CONFIGURE_LVM" =~ ^[Yy]$ ]]; then
    # 1. Check if the logical volume exists
    # 2. Check if the Volume Group has more than 0 free space
    VG_NAME="ubuntu-vg"
    LV_PATH="/dev/ubuntu-vg/ubuntu-lv"
    
    if lvs "$LV_PATH" &>/dev/null; then
        FREE_SPACE=$(vgs "$VG_NAME" --noheadings -o vg_free_count | xargs)
        # Convert extents to approximate GB (assuming 4MB extents)
        FREE_GB=$(vgs "$VG_NAME" --noheadings --units g -o vg_free | xargs | tr -d 'g')
        
        if [ "$FREE_SPACE" -gt 0 ]; then
            #echo "LVM detected with $FREE_SPACE free extents."
            echo "LVM detected. Free space in Volume Group: ${FREE_GB}GB"
    
            read -p "Resize root LVM? (y/n): " DO_RESIZE
            if [[ "$DO_RESIZE" =~ ^[Yy]$ ]]; then
                read -p "Enter target size in GB (or type 'all'): " TARGET_GB
                
                if [ "$TARGET_GB" == "all" ]; then
                    lvextend -l +100%FREE "$LV_PATH"
                else
                    lvextend -L "${TARGET_GB}G" "$LV_PATH"
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
        read -p "Would you like to create a swap file? (y/n): " CONFIGURE_SWAP
        
        if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ ]]; then
            # Ask for size with a sensible default
            read -p "Enter swap size in GB [Default: 2]: " SWAP_SIZE_GB
            SWAP_SIZE_GB=${SWAP_SIZE_GB:-2} # Fallback to 2 if empty
            
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
echo "--- 9. Install recommended packages ---"
if [[ "$INSTALL_PACKAGES" =~ ^[Yy]$ ]]; then
    wait_for_apt
    apt-get install $APT_FLAGS micro nmap ne nano vim vim-gui-common mc speedtest-cli btop \
    iftop ncdu lsof sysstat iotop lynis network-manager net-tools debsums apt-show-versions \
    iputils-ping unattended-upgrades gnupg2 curl wget git git-lfs jq sed ca-certificates \
    gnupg lsb-release apt-utils nmap gpg 
else
    echo "Skipping installation."
fi


echo ""
echo "--- 10. Install and configure ufw firewall ---"
if [[ "$INSTALL_UFW" =~ ^[Yy]$ ]]; then
    wait_for_apt
    apt-get -y install ufw rsyslog
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
    mkdir -p /home/$MY_SUDO_USERNAME/.ssh
    chown $MY_SUDO_USERNAME:$MY_SUDO_USERNAME /home/$MY_SUDO_USERNAME/.ssh
    chmod 700 /home/$MY_SUDO_USERNAME/.ssh
    AUTH_KEYS="/home/$MY_SUDO_USERNAME/.ssh/authorized_keys"
    if [ ! -f "$AUTH_KEYS" ] || [ ! -s "$AUTH_KEYS" ]; then
        echo "SSH KEY SETUP"
        echo "No existing keys found for $MY_SUDO_USERNAME."
        echo "Please paste your SSH PUBLIC KEY (starts with ssh-rsa, ssh-ed25519, etc.):"
        read -r SSH_PUBLIC_KEY
        if [ -n "$SSH_PUBLIC_KEY" ]; then
            mkdir -p /home/$MY_SUDO_USERNAME/.ssh
            echo "$SSH_PUBLIC_KEY" > "$AUTH_KEYS"
            chmod 700 /home/$MY_SUDO_USERNAME/.ssh
            chmod 600 "$AUTH_KEYS"
            chown -R $MY_SUDO_USERNAME:$MY_SUDO_USERNAME /home/$MY_SUDO_USERNAME/.ssh
            echo "SSH key installed for $MY_SUDO_USERNAME."
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
    # Using <<EOF, not <<'EOF', so that $MY_SUDO_USERNAME is replaced.
    cat <<EOF > /etc/ssh/sshd_config.d/01-$MY_SUDO_USERNAME-hardened.conf
UsePAM yes
PermitRootLogin no
ChallengeResponseAuthentication no
PasswordAuthentication no
PermitEmptyPasswords no
MaxStartups 3:50:10
LoginGraceTime 10
MaxAuthTries 3
PubkeyAuthentication yes
AllowUsers $MY_SUDO_USERNAME
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
    echo "--- 12. Override sudo settings ---"
    echo "Defaults timestamp_timeout=60" > /etc/sudoers.d/$MY_SUDO_USERNAME-timeout
    echo "$MY_SUDO_USERNAME ALL=(ALL) NOPASSWD:/usr/bin/apt-get update, /usr/bin/apt-get upgrade, /usr/bin/systemctl, /usr/sbin/reboot, /home/$MY_SUDO_USERNAME/ubuntu_health_check.sh" > /etc/sudoers.d/$MY_SUDO_USERNAME-commands
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
    echo "--- 13. Override update timer settings ---"
    mkdir -p /etc/systemd/system/apt-daily.timer.d/
    echo -e "[Timer]\nOnCalendar=*-*-* 10,22:00" > /etc/systemd/system/apt-daily.timer.d/override.conf
    mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d/
    echo -e "[Timer]\nOnCalendar=*-*-* 10:00" > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf
    systemctl daemon-reload
    
    
    echo ""
    echo "--- 14. Configure system file limits ---"
    rm -f /etc/security/limits.d/xlvisuals.conf
    cat <<'EOF' > /etc/security/limits.d/xlvisuals.conf
# XLVISUALS recommended limits

* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF
    
    
    echo ""
    echo "--- 15. Kernel tuning and hardening ---"
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
    echo "--- 16. Secure Shared Memory ---"
    # allow MySQL to write to the memory space, but prevents an attacker from running executables or gain root
    if ! grep -q "none /run/shm tmpfs" /etc/fstab; then
        echo "none /run/shm tmpfs defaults,nosuid,nodev,noexec 0 0" >> /etc/fstab
    fi
    # Re-mount immediately to apply changes without reboot
    mount -o remount,nosuid,nodev,noexec /run/shm 2>/dev/null || true
    
else
    echo ""
    echo "--- 12.-16. System Tuning ---"
    echo "Skipping system tuning steps."
fi


echo ""
echo "--- 17. Install fonts ---"
if [[ "$INSTALL_FONTS" =~ ^[Yy]$ ]]; then
    # install fonts
    echo ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true | debconf-set-selections
    wait_for_apt
    apt-get install $APT_FLAGS fonts-liberation fonts-freefont-ttf ttf-mscorefonts-installer
    fc-cache -f -v
else
    echo "Skipping fonts installation."
fi


echo ""
echo "--- 18. Install Python 3.14 ---"
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
echo "--- 19. Install PyPy 3.11 ---"
if [[ "$INSTALL_PYPY311" =~ ^[Yy]$ ]]; then

    # Fetch latest PyPy 3.11 version dynamically, fall back to known version if unavailable
    PYPY_BASE_URL="https://downloads.python.org/pypy"
    PYPY_FILENAME=$(curl -fsSL https://downloads.python.org/pypy/versions.json | grep -oP 'pypy3\.11-v[\d.]+-linux64\.tar\.bz2' | sort -V | tail -n1) || true
    if [[ -z "$PYPY_FILENAME" ]]; then
        echo "Could not determine latest PyPy 3.11 version. Falling back to $PYPY311_VERSION."
        PYPY_FILENAME="${PYPY311_VERSION}.tar.bz2"
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
echo "--- 20. Install weasyprint ---"
if [[ "$INSTALL_WEASYPRINT" =~ ^[Yy]$ ]]; then
    wait_for_apt
    apt-get install $APT_FLAGS weasyprint
else
    echo "Skipping weasyprint installation."
fi


echo ""
echo "--- 21. Install imagemagick ---"
if [[ "$INSTALL_IMAGEMAGICK" =~ ^[Yy]$ ]]; then
    wait_for_apt
    apt-get install $APT_FLAGS imagemagick
else
    echo "Skipping imagemagick installation."
fi


echo ""
echo "--- 22. Install nginx ---"
if [[ "$INSTALL_NGINX" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_NGINX" == 'reinstall' ]]; then
        echo "Uninstall nginx"
        wait_for_apt
        apt-get purge -y nginx || true
    fi
    wait_for_apt
    # apache2-utils needed for htpasswd utility
    apt-get install $APT_FLAGS nginx apache2-utils
    usermod -a -G $MY_SUDO_USERNAME www-data
    systemctl enable --now nginx || true
    
    if command -v ufw >/dev/null && ufw status | grep -q active; then
        ufw allow 80/tcp
        ufw allow 443/tcp
    fi
else
    echo "Skipping nginx installation."
fi


echo ""
echo "--- 23. Install Valkey ---"
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
echo "--- 24. Install MySQL ---"
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
    
    mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root mysql
    
    # Secure MySQL using the provided password
    # ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASS_ESCAPED}';
    mysql -u root <<EOS
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_PASS_ESCAPED}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOS

    # Clear the variable from memory for security
    unset MYSQL_PASS
    unset MYSQL_PASS_CONFIRM
    unset MYSQL_PASS_ESCAPED
    echo "MySQL root password set and security initialized."
else
    echo "Skipping MySQL installation."
fi


echo ""
echo "--- 25. Install PostgreSQL $PG_VERSION ---"
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
        
        echo "Hardening PostgreSQL configuration..."
        
        # Listen only on localhost
        sed -i "s/^#listen_addresses.*/listen_addresses = 'localhost'/" "$PG_CONF"
        
        # Secure authentication rules
        cat > "$PG_HBA" <<EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local connections
local   all             postgres                                peer
local   all             all                                     peer

# IPv4 localhost
host    all             all             127.0.0.1/32            scram-sha-256

# IPv6 localhost
host    all             all             ::1/128                 scram-sha-256
EOF
    
        echo "Enabling PostgreSQL..."
        systemctl enable --now postgresql || echo "Warning: service failed to start"
    else
        echo "Could not download gpg key. Skipping installation."
    fi
else
    echo "Skipping PostgreSQL installation."
fi


echo ""
echo "--- 26. Install Mosquitto MQTT broker ---"
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
echo "--- 27. Install Monit ---"
if [[ "$INSTALL_MONIT" =~ ^[Yy]$ ]]; then
    if [[ "$PROMPT_MONIT" == 'reinstall' ]]; then
        echo "Uninstall monit"
        wait_for_apt
        apt-get purge -y monit  || true
    fi
    wait_for_apt
    apt-get install $APT_FLAGS monit
    systemctl enable --now monit.service || echo "Warning: service failed to start"
else
    echo "Skipping Monit installation."
fi


# Old manual method
# echo ""
# echo "--- 28. Install Webmin ---"
# if [[ "$INSTALL_WEBMIN" =~ ^[Yy]$ ]]; then
#     if [[ "$PROMPT_WEBMIN" == 'reinstall' ]]; then
#         echo "Uninstall webmin"
#         wait_for_apt
#         apt-get purge -y webmin  || true
#     fi
#     
#     # Keys for 3rd-party repos go into /etc/apt/keyrings/, not /usr/share/keyrings/
#     mkdir -p /etc/apt/keyrings/
#     rm -f /etc/apt/keyrings/webmin.gpg || true
#     rm -f /usr/share/keyrings/webmin.gpg || true
#     
#     
#     # Check https://webmin.com/download/ for current key URL
#     # curl -fsSL https://download.webmin.com/developers-key.asc | gpg --dearmor -o /etc/apt/keyrings/webmin.gpg || true
#     curl -fsSL https://www.webmin.com/jcameron-key.asc | gpg --dearmor -o /etc/apt/keyrings/webmin.gpg || true
#     sudo chmod 644 /etc/apt/keyrings/webmin.gpg
#     
#     if [[ -f "/etc/apt/keyrings/webmin.gpg" &&  -s "/etc/apt/keyrings/webmin.gpg" ]]; then
#         echo "deb [signed-by=/etc/apt/keyrings/webmin.gpg] https://download.webmin.com/download/newkey/repository stable contrib" > /etc/apt/sources.list.d/webmin.list
#         wait_for_apt
#         apt-get update
#         apt-get install $APT_FLAGS webmin
#         systemctl enable --now webmin.service || echo "Warning: service failed to start"
#     else
#         echo "Could not download gpg key. Skipping installation."
#     fi
# else
#     echo "Skipping Webmin installation."
# fi

echo ""
echo "--- 28. Install Webmin ---"
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
echo "--- 29. Install Grafana ---"
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
    sudo chmod 644 /etc/apt/keyrings/grafana.gpg
    
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
        usermod -a -G grafana $MY_SUDO_USERNAME
        systemctl enable --now grafana-server.service || echo "Warning: service failed to start"
    else
        echo "Could not download gpg key. Skipping installation."
    fi
else
    echo "Skipping Grafana installation."
fi


echo ""
echo "--- 30. Install Forgejo ---"
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
        usermod -a -G git $MY_SUDO_USERNAME
        
        # cleanup
        rm -f forgejo-latest || true
        
        # configure
        if [[ "$INSTALL_GRAFANA" =~ ^[Yy]$ ]]; then
            # Grafana and Forgejo both user port 3000 by default. -> Change Forgejo port to 3030
            echo "Installing Forgejo on port 3030"
            cat <<'EOF' > /etc/forgejo/app.ini
[server]
SSH_DOMAIN = 127.0.0.1
DOMAIN = 127.0.0.1
HTTP_PORT = 3030
ROOT_URL = http://127.0.0.1:3030/
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


echo ""
echo "--- 31. Install Fail2Ban ---"
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
echo "--- 32. Install auditd ---"
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
echo "--- 33. Install ip blocklist (ipset + ipsum) ---"
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
    cp "$TEMP_DIR/after.init" /etc/ufw/after.init
    cp "$TEMP_DIR/ufw-blocklist-ipsum" /etc/cron.daily/ufw-blocklist-ipsum
    
    # Set ownership and permissions
    chown root:root /etc/ufw/after.init /etc/cron.daily/ufw-blocklist-ipsum
    chmod 750 /etc/ufw/after.init /etc/cron.daily/ufw-blocklist-ipsum
    
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
echo "--- 34. Install Suricata IDS ---"
if [[ "$INSTALL_SURICATA" =~ ^[Yy]$ ]]; then
    # The idea is that wazuh agent monitors /var/log/suricata/eve.json for attacks and responses are configured and triggered via wazuh manager
    
    if [[ "$PROMPT_SURICATA" == 'reinstall' ]]; then
        echo "Uninstall suricata"
        # Backup original config
        cp /etc/suricata/suricata.yaml /etc/suricata/suricata.yaml.bak
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
echo "--- 35. Install and configure Wazuh Agent (Optional) ---"
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
echo "--- 36. Finalise installation ---"

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

HEALTH_CHECK_SCRIPT="/home/$MY_SUDO_USERNAME/ubuntu_health_check.sh"

echo ""
echo "--- 37. Generating Custom Health Check Script 'ubuntu_health_check.sh' ---"
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
echo "       XLVISUALS SERVER HEALTH CHECK "
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
        read -p "Would you like to set swappiness to 10 now? (y/n): " FIX_SWAP
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

echo "==========================================="
EOF

chown $MY_SUDO_USERNAME:$MY_SUDO_USERNAME $HEALTH_CHECK_SCRIPT
chmod +x $HEALTH_CHECK_SCRIPT

# Run health check 
$HEALTH_CHECK_SCRIPT

echo ""
echo "--- SETUP COMPLETE ---"
echo "Logfile written to: $LOG_FILE"
echo "Original configs backed up to: $BACKUP_DIR"
echo ""
echo "Port usage:"
[[ "$INSTALL_NGINX" =~ ^[Yy]$ ]]      && echo "Installed nginx on ports 80 and 443"
[[ "$INSTALL_VALKEY" =~ ^[Yy]$ ]]     && echo "Installed valkey-server on port 6379"
[[ "$INSTALL_MYSQL" =~ ^[Yy]$ ]]      && echo "Installed mysql on port 3306"
[[ "$INSTALL_POSTGRESQL" =~ ^[Yy]$ ]] && echo "Installed postgresql on port 5432"
[[ "$INSTALL_MOSQUITTO" =~ ^[Yy]$ ]]  && echo "Installed mosquitto on port 1883"
[[ "$INSTALL_MONIT" =~ ^[Yy]$ ]]      && echo "Installed monit on port 2812"
[[ "$INSTALL_WEBMIN" =~ ^[Yy]$ ]]     && echo "Installed webmin on port 10000"
[[ "$INSTALL_GRAFANA" =~ ^[Yy]$ ]]    && echo "Installed grafana-server on port 3000"
[[ "$INSTALL_FORGEJO" =~ ^[Yy]$ ]] && [[ ! "$INSTALL_GRAFANA" =~ ^[Yy]$ ]] && echo "Installed forgejo on port 3000"
[[ "$INSTALL_FORGEJO" =~ ^[Yy]$ ]] && [[ "$INSTALL_GRAFANA" =~ ^[Yy]$ ]]   && echo "Installed forgejo on port 3030"
echo ""
echo "ACTION REQUIRED: Test SSH login in a NEW window before closing this one or you may be locked out."
echo "ACTION REQUIRED: Reboot the system to apply all changes."

