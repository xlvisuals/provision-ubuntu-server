#!/bin/bash
# UBUNTU 24.04 and 26.04 SERVER STATUS CHECK SCRIPT

# Define terminal colors for the status column
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Helper functions 

service_status() {
    local service="$1"
    local units

    # Simple check for Webmin if it runs standalone/legacy init setups
    if [ "$service" == "webmin" ] && [ ! -f /lib/systemd/system/webmin.service ] && [ -f /etc/webmin/version ]; then
        if pgrep -f webmin >/dev/null; then echo -e "${GREEN}RUNNING${NC}"; else echo -e "${YELLOW}STOPPED${NC}"; fi
        return
    fi

    units=$(systemctl list-unit-files "${service}.service" 2>/dev/null) || true
    if ! echo "$units" | grep -q "${service}.service"; then
        echo -e "${RED}NOT INSTALLED${NC}"
    elif systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "${GREEN}RUNNING${NC}"
    elif systemctl is-failed --quiet "$service" 2>/dev/null; then
        echo -e "${RED}FAILED${NC}"
    else
        echo -e "${YELLOW}STOPPED${NC}"
    fi
}


process_service() {
    local item="$1"
    local display_name pkg_name bin_name svc_name
    IFS="|" read -r display_name pkg_name bin_name svc_name <<< "$item"

    local version=""
    local bin_path=""

    # 1. First Pass: Check dpkg / apt repository status
    if dpkg-query -W -f='${Status}\n' "$pkg_name" 2>/dev/null | grep -q "install ok installed"; then
        version=$(dpkg-query -W -f='${Version}\n' "$pkg_name" 2>/dev/null | sed 's/^[0-9]*://')

    # 2. Second Pass: Check if the binary exists for standalone/manual installs (e.g. Forgejo)
    elif command -v "$bin_name" &>/dev/null || [ -x "/usr/sbin/$bin_name" ] || [ -x "/usr/local/bin/$bin_name" ]; then
        bin_path=$(command -v "$bin_name" || echo "/usr/sbin/$bin_name")

        case "$bin_name" in
            "nginx")           version=$($bin_path -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1) ;;
            "valkey-server")   version=$($bin_path --version 2>/dev/null | grep -oE 'v=[0-9]+\.[0-9]+\.[0-9]+' | cut -d= -f2) ;;
            "mysql")           version=$($bin_path -V 2>/dev/null | grep -oE 'Ver [0-9]+\.[0-9]+\.[0-9]+[^ ]*' | awk '{print $2}') ;;
            "mariadb")         version=$($bin_path -V 2>/dev/null | grep -oE 'Ver [0-9]+\.[0-9]+\.[0-9]+[^ ]*' | awk '{print $2}') ;;
            "mosquitto")       version=$($bin_path -h 2>/dev/null | grep -i version | awk '{print $3}') ;;
            "postfix")         version=$(postconf -d mail_version 2>/dev/null | awk '{print $3}') ;;
            "monit")           version=$($bin_path -V 2>/dev/null | grep -i version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+') ;;
            "webmin")          [ -f /etc/webmin/version ] && version=$(cat /etc/webmin/version) ;;
            "grafana-server")  version=$($bin_path -v 2>/dev/null | awk '{print $2}') ;;
            "forgejo")         version=$($bin_path -v 2>/dev/null | awk '{print $3}') ;;
            "fail2ban-client") version=$($bin_path -v 2>&1 | grep -i fail2ban | awk '{print $3}' | sed 's/v//') ;;
            "auditd")          version=$($bin_path -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*') ;;
            "suricata")        version=$($bin_path -V 2>/dev/null | awk '{print $5}') ;;
            "wazuh-agent")     version=$(grep -oP '(?<=<version>)[^<]+' /var/ossec/etc/ossec.conf 2>/dev/null | head -1) ;;
        esac
    fi

    # 3. Third Pass: Edge cases for binaries with unique alternate names (like psql vs postgresql)
    if [ -z "$version" ] && [ "$bin_name" == "postgresql" ] && command -v psql &>/dev/null; then
        version=$(psql -V 2>/dev/null | awk '{print $3}')
    fi

    local status_state
    status_state=$(service_status "$svc_name")

    # If not in systemd but binary found, mark as binary-only rather than not installed
    [[ "$status_state" == *"NOT INSTALLED"* ]] && [ -n "$version" ] && status_state="- (Binary Only)"

    [ -z "$version" ] && version="-"

    printf "%-18s | %-32s | %b\n" "$display_name" "$version" "$status_state"
}


# Map the display name to its formal Debian package name, binary name, and systemd service name
# Format: "Display Name|apt-package-name|binary-name|systemd-service-name"
services=(
    "Nginx|nginx|nginx|nginx"
    "Valkey Server|valkey-server|valkey-server|valkey-server"
    "MySQL|mysql-server|mysql|mysql"
    "MariaDB|mariadb-server|mariadb|mariadb"
    "PostgreSQL|postgresql|postgresql|postgresql"
    "Mosquitto|mosquitto|mosquitto|mosquitto"
    "Postfix|postfix|postfix|postfix"
    "Monit|monit|monit|monit"
    "Webmin|webmin|webmin|webmin"
    "Grafana Server|grafana|grafana-server|grafana-server"
    "Forgejo|forgejo|forgejo|forgejo"
    "Fail2Ban|fail2ban|fail2ban-client|fail2ban"
    "Auditd|auditd|auditd|auditd"
    "Suricata|suricata|suricata|suricata"
    "Wazuh Agent|wazuh-agent|wazuh-agent|wazuh-agent"
)

echo -e "\n======================================================================="
printf "%-18s | %-32s | %s\n" "SERVICE NAME" "VERSION" "STATUS"
echo -e "=======================================================================\n"

for item in "${services[@]}"; do
    process_service "$item"
done

echo -e "\n======================================================================="