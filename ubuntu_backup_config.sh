#!/usr/bin/env bash
# ubuntu_backup_config.sh - System Configuration Backup for Ubuntu 24.04 LTS and 26.04 LTS
# Usage: sudo ./ubuntu_backup_config.sh [BACKUPPOSTFIX]
# - includes apt packages
# - includes users, groups, ssh keys, cron jobs, systemd service and timer overrides, letsencrypt certificates, grafana db, and forgejo db, postfix aliases
# - includes configurations for forgejo, grafana, letsencrypt, monit, mosquitto, mysql, nginx, nginx, postfix, postgresql, valkey, valkey, wazuh, webmin
# - includes GPG keys for external repositories so apt update doesn't throw errors during the restore 
# - DOES NOT include binary installations (e.g. wazuh, forgejo). Please install these separately on the target.
# - DOES NOT include network config, disk config, swap config
# - DOES NOT include mysql/mariadb databases and postgresql databases. Only service configurations.
# - if no BACKUPPOSTFIX parameter is supplied, the script uses the IP address for identification


REQUIRED_PATHS=(
    "/etc/login.defs" "/etc/sysctl.conf" "/etc/security/limits.conf" 
    "/etc/rsyslog.d/20-ufw.conf" "/etc/ssh" "/etc/ufw" "/etc/cron.d" "/etc/crontab" 
    "/etc/logrotate.d" "/etc/passwd" "/etc/group" "/etc/shadow" "/etc/sudoers" 
    "/etc/sudoers.d/" "/etc/apt/sources.list.d" "/etc/apt/sources.list" 
    "/usr/share/keyrings" "/etc/apt/keyrings" "/etc/apt/trusted.gpg"
    "/etc/apt/apt.conf.d/50unattended-upgrades" "/etc/apt/apt.conf.d/20auto-upgrades"
    "/etc/webmin" "/etc/monit" "/etc/mysql" "/etc/nginx" "/etc/valkey" "/etc/grafana" 
    "/etc/mosquitto" "/etc/letsencrypt" "/etc/suricata" "/etc/forgejo"
    "/var/ossec/etc" "/var/ossec/api/configuration" "/var/ossec/var/lib/wazuh-keystore"
    "/etc/wazuh-indexer/certs" "/etc/wazuh-dashboard/certs" 
    "/var/lib/forgejo/data/forgejo.db" "/var/lib/grafana/grafana.db"
    "/etc/postgresql" "/etc/postfix" "/etc/aliases"
    "/etc/ssh/sshd_config.d/01-xlvisuals-hardened.conf"
    "/etc/systemd/system/apt-daily.timer.d/override.conf"
    "/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf"
    "/etc/security/limits.d/xlvisuals.conf"
    "/etc/sysctl.d/99-xlvisuals.conf"
    "/etc/fail2ban/jail.local"
    "/etc/audit/rules.d/audit.rules"
    "/etc/ufw/after.init" "/etc/cron.daily/ufw-blocklist-ipsum" "/etc/ipsum.4.txt"
)

cd "${0%/*}" || exit

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)."
   exit 1
fi

LOCAL_IP=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+')

BACKUPNAME="$1"
if [[ $BACKUPNAME == '' ]]; then
    BACKUPNAME="$LOCAL_IP"
fi

BACKUP_DIR="/tmp/server_backup"
FILES_DIR="$BACKUP_DIR/files"
CONF_ARCHIVE="ubuntu_config_${BACKUPNAME}_$(date +%F_%H%M%S).tar.gz"

if [[ "$FILES_DIR" != '/' ]]; then
    rm -rf "$FILES_DIR"
fi
mkdir -p "$FILES_DIR"


echo "--- Starting Backup ---"

# 1. Capture Installed Packages
echo "[*] Saving installed package list..."
dpkg --get-selections > "$FILES_DIR/package_list.txt"

# 2. Copy files (Preserving symlinks and permissions)
for path in "${REQUIRED_PATHS[@]}"; do
    if [ -e "$path" ]; then
        echo "[*] Copying $path..."
        cp -a --parents "$path" "$FILES_DIR/"
    else
        echo "[!] Warning: $path not found."
    fi
done

# echo "[*] Saving systemd timers and service"
# cp -p /etc/systemd/system/*.timer "$FILES_DIR/etc/systemd/system/" 2>/dev/null
# cp -p /etc/systemd/system/*.service "$FILES_DIR/etc/systemd/system/" 2>/dev/null

echo "[*] Saving systemd service and timer override directories"
cp -pr /etc/systemd/system/*.service.d "$FILES_DIR/etc/systemd/system/" 2>/dev/null
cp -pr /etc/systemd/system/*.timer.d "$FILES_DIR/etc/systemd/system/" 2>/dev/null


# 3. Verification
echo "--- Verifying Backup ---"
MISSING=0

for path in "${REQUIRED_PATHS[@]}"; do
    # Only verify if the original source path actually exists
    if [ -e "$path" ]; then
        if [ ! -e "$FILES_DIR$path" ]; then
            echo "[X] Error: $path exists on system but is missing in backup folder!"
            MISSING=$((MISSING + 1))
        fi
    else
        echo "[-] Skipping $path (not present on source system)"
    fi
done


# 4. Packaging
if [ $MISSING -eq 0 ]; then
    echo "[V] Total missing items: $MISSING"
    tar -czf "$CONF_ARCHIVE" -C "$FILES_DIR" .
    chown $SUDO_USER:$SUDO_USER "$CONF_ARCHIVE"
    echo "[V] Success! Backup saved to: $CONF_ARCHIVE"
else
    echo "[!] Total missing items: $MISSING"
    echo "[X] Backup failed verification. Tarball not created."
    exit 1
fi

# 5. Remove temporary files dir
if [[ "$FILES_DIR" != '/' ]]; then
    rm -rf "$FILES_DIR"
    echo "[V] Removed temporary files."
fi
