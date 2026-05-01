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
    else
        echo -e "AppArmor: ${RED}[DISABLED]${NC}"
    fi
else
    echo -e "AppArmor: ${RED}[NOT INSTALLED]${NC}"
fi

echo "==========================================="