#!/bin/bash
# UBUNTU 24.04 and 26.04 SERVER HEALTH CHECK SCRIPT
# by Axel Busch

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
check_service_status() {
    local service="$1"
    local name="$2"
    local units
    units=$(systemctl list-unit-files "${service}.service" 2>/dev/null) || true
    if ! echo "$units" | grep -q "${service}.service"; then
        echo -e "$name: ${RED}[NOT INSTALLED]${NC}"
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
    if ufw status | grep -qE "^${port}(/tcp)?\s+ALLOW"; then
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
    if mysql -u healthcheck -e "SELECT 1;" mysql &>/dev/null; then
        smoke_ok "MySQL: connection OK"
    else
        smoke_warn "MySQL: connection failed — check service status"
    fi
else smoke_skip "MySQL"; fi

if systemctl is-active --quiet mariadb 2>/dev/null; then
    if mysql -u healthcheck -e "SELECT 1;" mysql &>/dev/null; then
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