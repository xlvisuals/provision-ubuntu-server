#!/bin/bash
# UBUNTU 24.04 and 26.04 SERVER HEALTH CHECK SCRIPT
# by Xlvisuals Limited
# Standalone copy: keep in sync with the copy embedded in ubuntu_provision.sh (step 50)

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
# sudo sshd -T | egrep -i '^(UsePAM|PermitRootLogin|KbdInteractiveAuthentication|PasswordAuthentication|PermitEmptyPasswords|MaxStartups|LoginGraceTime|MaxAuthTries|PubkeyAuthentication|AllowUsers|ClientAliveInterval|ClientAliveCountMax|MaxSessions|AllowTcpForwarding|AllowAgentForwarding|PermitTunnel|TCPKeepAlive|X11Forwarding|IgnoreRhosts|AuthenticationMethods|PrintMotd) '
# Fetch the active runtime configuration from sshd
# Anchored (^...<space>): otherwise 'MaxStartups' also matches PerSourceMaxStartups, which has no rule.
sudo sshd -T | egrep -i '^(UsePAM|PermitRootLogin|KbdInteractiveAuthentication|PasswordAuthentication|PermitEmptyPasswords|MaxStartups|LoginGraceTime|MaxAuthTries|PubkeyAuthentication|AllowUsers|ClientAliveInterval|ClientAliveCountMax|MaxSessions|AllowTcpForwarding|AllowAgentForwarding|PermitTunnel|TCPKeepAlive|X11Forwarding|IgnoreRhosts|AuthenticationMethods|PrintMotd) ' | \
while read -r param value; do
    # Normalize parameter name to lowercase for easy matching
    param_lower=$(echo "$param" | tr '[:upper:]' '[:lower:]')
    is_safe=false

    case "$param_lower" in
        # These parameters should strictly be "no"
        # tcpkeepalive: "no" is the hardened value; ClientAliveInterval does the (encrypted, unspoofable) keepalive instead
        permitrootlogin|passwordauthentication|kbdinteractiveauthentication|permitemptypasswords|x11forwarding|allowagentforwarding|permittunnel|tcpkeepalive)
            if [ "$value" = "no" ]; then is_safe=true; fi
            ;;
        # These parameters should strictly be "yes"
        usepam|pubkeyauthentication|ignorerhosts|printmotd)
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
        # ClientAliveInterval must be on (0 = off, then ClientAliveCountMax does nothing) and at most 5 minutes
        clientaliveinterval)
            if [ "$value" -ge 1 ] && [ "$value" -le 300 ]; then is_safe=true; fi
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
echo "Inodes"
echo "==========================================="
INODE_PCT=$(df -i / | awk 'NR==2 {gsub("%","",$5); print $5}')
if [[ "$INODE_PCT" =~ ^[0-9]+$ ]]; then
    if [ "$INODE_PCT" -ge 90 ]; then
        echo -e "Root filesystem inodes: ${INODE_PCT}% used -> ${RED}[WARNING]${NC}"
    else
        echo -e "Root filesystem inodes: ${INODE_PCT}% used -> ${GREEN}[OK]${NC}"
    fi
else
    echo "Could not determine inode usage."
fi

echo ""
echo "Uptime and load"
echo "==========================================="
echo "Uptime : $(uptime -p)"
LOAD1=$(cut -d' ' -f1 /proc/loadavg)
echo "Load   : $(cut -d' ' -f1-3 /proc/loadavg) ($(nproc) cores)"
if awk -v l="$LOAD1" -v c="$(nproc)" 'BEGIN {exit !(l > c)}'; then
    echo -e "  1-min load exceeds core count -> ${YELLOW}[HIGH]${NC}"
fi

echo ""
echo "Reboot required"
echo "==========================================="
if [ -f /var/run/reboot-required ]; then
    echo -e "${YELLOW}[REBOOT REQUIRED]${NC}"
    cat /var/run/reboot-required.pkgs 2>/dev/null | sort -u | sed 's/^/  /'
else
    echo -e "${GREEN}[NO REBOOT NEEDED]${NC}"
fi

echo ""
echo "Time synchronisation"
echo "==========================================="
if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
    echo -e "Clock synchronised -> ${GREEN}[OK]${NC}"
else
    echo -e "Clock NOT synchronised -> ${RED}[WARNING]${NC}"
fi
echo "Timezone: $(timedatectl show -p Timezone --value 2>/dev/null)"

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
echo "Network traffic (vnstat)"
echo "==========================================="
if ! command -v vnstat &>/dev/null; then
    echo -e "vnstat: ${GREY}[NOT INSTALLED]${NC}"
elif ! systemctl is-active --quiet vnstat.service 2>/dev/null; then
    echo -e "vnstat: ${RED}[SERVICE NOT RUNNING]${NC}  (try: sudo systemctl enable --now vnstat)"
else
    if vnstat -i "$PRIMARY_INTERFACE" &>/dev/null; then
        echo "Interface: $PRIMARY_INTERFACE"
        echo ""
        echo "Last 3 days:"
        vnstat -i "$PRIMARY_INTERFACE" -d 3 2>/dev/null | tail -n +4 | sed 's/^/  /'
        echo ""
        echo "Last 2 months:"
        vnstat -i "$PRIMARY_INTERFACE" -m 2 2>/dev/null | tail -n +4 | sed 's/^/  /'
    else
        echo -e "No data for $PRIMARY_INTERFACE yet -> ${YELLOW}[COLLECTING]${NC}"
        echo "  vnstat needs a few minutes after install to start recording."
        echo "  If the interface is missing: sudo vnstat --add -i $PRIMARY_INTERFACE"
    fi
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
echo "Held packages (skipped by automatic upgrades)"
echo "==========================================="
HELD_LIST=$(apt-mark showhold 2>/dev/null)
if [[ -z "$HELD_LIST" ]]; then
    echo "  None"
else
    HELD_WAITING=0
    while read -r hp; do
        [[ -n "$hp" ]] || continue
        hp_inst=$(dpkg-query -W -f='${Version}' "$hp" 2>/dev/null) || continue
        hp_cand=$(apt-cache policy "$hp" 2>/dev/null | awk '/^ +Candidate:/ {print $2; exit}')
        if [[ -n "$hp_cand" && "$hp_cand" != "(none)" ]] && dpkg --compare-versions "$hp_cand" gt "$hp_inst"; then
            echo -e "  $hp $hp_inst: ${YELLOW}[UPDATE AVAILABLE: $hp_cand]${NC}"
            HELD_WAITING=$((HELD_WAITING + 1))
        else
            echo -e "  $hp $hp_inst: ${GREEN}[up to date]${NC}"
        fi
    done <<<"$HELD_LIST"
    (( HELD_WAITING > 0 )) && echo -e "  ${YELLOW}$HELD_WAITING held package(s) have updates: sudo upgrade-held-packages${NC}"
    if [[ -x /usr/local/sbin/held-package-updates && -f /etc/systemd/system/apt-daily.service.d/held-package-updates.conf ]]; then
        HELD_MAIL=$(sed -n 's/^MAIL_TO=//p' /etc/held-package-updates.conf 2>/dev/null | head -1)
        echo -e "  Update notice mail: ${GREEN}[to ${HELD_MAIL:-?}]${NC}"
    else
        echo -e "  Update notice mail: ${RED}[NOT CONFIGURED - you will not be told when an update is waiting]${NC}"
    fi
fi

echo ""
echo "Service status"
echo "==========================================="
echo -n "UFW Firewall "
ufw status | grep -q "^Status: active" && echo -e "${GREEN}[ACTIVE]${NC}" || echo -e "${RED}[INACTIVE]${NC}"
check_service_status "nginx" "NGINX Web Server"
# Coraza WAF module: only reported if it was built by utils/install_coraza_nginx.sh
echo -n "Coraza WAF module "
if [[ ! -f /var/lib/coraza-nginx/build.stamp ]]; then
    echo -e "${GREY}[NOT INSTALLED]${NC}"
elif /usr/local/sbin/install_coraza_nginx.sh check >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} mode: $(grep -oP '^SecRuleEngine \K\S+' /etc/nginx/coraza/coraza.conf 2>/dev/null || echo unknown)"
else
    echo -e "${RED}[MISMATCH OR BROKEN]${NC} - run: sudo /usr/local/sbin/install_coraza_nginx.sh"
fi
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
check_service_status "wazuh-indexer" "Wazuh Indexer"
check_service_status "wazuh-manager" "Wazuh Manager"
check_service_status "filebeat" "Filebeat (Wazuh)"
check_service_status "wazuh-dashboard" "Wazuh Dashboard"
check_service_status "postfix" "Postfix Mail Relay"
check_service_status "vnstat" "vnStat Traffic Monitor"
check_service_status "unattended-upgrades" "Unattended Upgrades"

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
    # Number of entries currently loaded in the ipset
    COUNT=$(sudo ipset list ufw-blocklist-ipsum 2>/dev/null | awk '/^Number of entries:/ {print $4}')
    # Last update time from syslog
    UPDATED=$(grep "finished updating ufw-blocklist-ipsum" /var/log/syslog 2>/dev/null | tail -1 | awk '{print $1}')
    echo -e "  Blocked IPs  : ${COUNT:-unknown}"
    echo -e "  Last updated : ${UPDATED:-unknown}"
else
    echo -e "  ${RED}[NOT ACTIVE]${NC}"
fi

echo ""
echo "Fail2Ban"
echo "==========================================="
if ! command -v fail2ban-client &>/dev/null; then
    echo -e "  Fail2Ban: ${GREY}[NOT INSTALLED]${NC}"
elif ! systemctl is-active --quiet fail2ban 2>/dev/null; then
    echo -e "  Fail2Ban: ${RED}[NOT RUNNING]${NC}"
else
    F2B_JAILS=$(fail2ban-client status 2>/dev/null | awk -F'Jail list:' '/Jail list:/ {gsub(/[ \t]/,"",$2); gsub(",", " ", $2); print $2}')
    if [[ -z "$F2B_JAILS" ]]; then
        echo -e "  No active jails -> ${YELLOW}[WARNING]${NC}"
    else
        for JAIL in $F2B_JAILS; do
            JSTAT=$(fail2ban-client status "$JAIL" 2>/dev/null)
            CUR_BANNED=$(echo "$JSTAT" | awk -F':' '/Currently banned/ {gsub(/[ \t]/,"",$2); print $2}')
            TOT_BANNED=$(echo "$JSTAT" | awk -F':' '/Total banned/ {gsub(/[ \t]/,"",$2); print $2}')
            CUR_FAILED=$(echo "$JSTAT" | awk -F':' '/Currently failed/ {gsub(/[ \t]/,"",$2); print $2}')
            echo "  Jail $JAIL: currently banned ${CUR_BANNED:-?}, total banned ${TOT_BANNED:-?}, currently failed ${CUR_FAILED:-?}"
            if [[ "${CUR_BANNED:-0}" =~ ^[0-9]+$ && "${CUR_BANNED:-0}" -gt 0 ]]; then
                echo "    Banned IPs: $(echo "$JSTAT" | awk -F':' '/Banned IP list/ {gsub(/^[ \t]+/,"",$2); print $2}')"
            fi
        done
    fi
fi

echo ""
echo "AIDE file integrity"
echo "==========================================="
if ! command -v aide &>/dev/null; then
    echo -e "  AIDE: ${GREY}[NOT INSTALLED]${NC}"
else
    AIDE_DB=""
    for f in /var/lib/aide/aide.db /var/lib/aide/aide.db.gz; do
        [[ -f "$f" ]] && AIDE_DB="$f" && break
    done
    if [[ -z "$AIDE_DB" ]]; then
        echo -e "  Database: ${RED}[MISSING]${NC} (run: sudo aideinit)"
    else
        echo "  Database     : $AIDE_DB (built $(date -r "$AIDE_DB" '+%Y-%m-%d %H:%M'))"
    fi
    if [[ -x /etc/cron.daily/aide-check ]]; then
        echo -e "  Daily check  : ${GREEN}[SCHEDULED]${NC}"
    else
        echo -e "  Daily check  : ${YELLOW}[NO CRON JOB]${NC}"
    fi
    AIDE_LOG=/var/log/aide/aide-check.log
    if [[ -s "$AIDE_LOG" ]]; then
        AIDE_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$AIDE_LOG") ) / 86400 ))
        echo "  Last check   : $(date -r "$AIDE_LOG" '+%Y-%m-%d %H:%M') (${AIDE_AGE_DAYS}d ago)"
        if [ "$AIDE_AGE_DAYS" -gt 2 ]; then
            echo -e "    -> ${YELLOW}[STALE]${NC} the daily check has not run recently"
        fi
        if grep -q "found differences between database and filesystem" "$AIDE_LOG"; then
            AIDE_ADDED=$(awk -F: '/^ *Added entries/   {gsub(/[ \t]/,"",$2); print $2}' "$AIDE_LOG" | head -1)
            AIDE_REMOVED=$(awk -F: '/^ *Removed entries/ {gsub(/[ \t]/,"",$2); print $2}' "$AIDE_LOG" | head -1)
            AIDE_CHANGED=$(awk -F: '/^ *Changed entries/ {gsub(/[ \t]/,"",$2); print $2}' "$AIDE_LOG" | head -1)
            echo -e "  Result       : ${YELLOW}[DIFFERENCES FOUND]${NC} added ${AIDE_ADDED:-?}, removed ${AIDE_REMOVED:-?}, changed ${AIDE_CHANGED:-?}"
            echo "    Review: sudo less $AIDE_LOG"
            echo "    After confirming the changes are legitimate: sudo aide --update && sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db"
        elif grep -q "looks okay" "$AIDE_LOG"; then
            echo -e "  Result       : ${GREEN}[NO CHANGES]${NC}"
        else
            echo -e "  Result       : ${RED}[CHECK FAILED / UNKNOWN]${NC} see $AIDE_LOG"
        fi
    else
        echo "  Last check   : no log yet (written by the daily job to $AIDE_LOG)"
    fi
fi

echo ""
echo "Certificate expiry"
echo "==========================================="
CERT_FILES=$(
    {
        ls /etc/letsencrypt/live/*/cert.pem 2>/dev/null
        grep -rhE '^\s*ssl_certificate\s' /etc/nginx/ 2>/dev/null | awk '{gsub(";","",$2); print $2}'
    } | sort -u
)
if [[ -z "$CERT_FILES" ]] || ! command -v openssl &>/dev/null; then
    echo "  No certificates found (Let's Encrypt or nginx ssl_certificate)."
else
    for CERT in $CERT_FILES; do
        [[ -r "$CERT" ]] || continue
        END=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)
        [[ -n "$END" ]] || continue
        DAYS=$(( ( $(date -d "$END" +%s) - $(date +%s) ) / 86400 ))
        if [ "$DAYS" -lt 0 ]; then
            echo -e "  $CERT: ${RED}[EXPIRED $((-DAYS))d ago]${NC}"
        elif [ "$DAYS" -lt 14 ]; then
            echo -e "  $CERT: ${RED}[${DAYS}d left]${NC}"
        elif [ "$DAYS" -lt 30 ]; then
            echo -e "  $CERT: ${YELLOW}[${DAYS}d left]${NC}"
        else
            echo -e "  $CERT: ${GREEN}[${DAYS}d left]${NC}"
        fi
    done
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
    if ufw status | grep -q "^Status: inactive"; then
        echo -e "${RED}[ALLOWED (UFW inactive)]${NC}"
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
check_port "wazuh-indexer"   "9200"
check_port "wazuh-manager"   "55000"
WZ_PORT_DASH=$(sed -n 's/^server\.port:[[:space:]]*\([0-9]\{1,5\}\).*/\1/p' /etc/wazuh-dashboard/opensearch_dashboards.yml 2>/dev/null | head -1)
[[ -n "$WZ_PORT_DASH" ]] && check_port "wazuh-dashboard" "$WZ_PORT_DASH"

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
# Catch-all default site (return 444 / ssl_reject_handshake): unknown hosts must get a closed connection
smoke_closed() {   # smoke_closed "label" url [curl args]
    local label="$1" url="$2" extra_args="${3:-}" code rc
    code=$(curl -s -o /dev/null -w "%{http_code}" -4 $extra_args --max-time 5 "$url" 2>/dev/null); rc=$?
    case "$rc" in
        52|35) smoke_ok "$label: connection closed for unknown host (catch-all)" ;;   # 52 empty reply, 35 TLS refused
        0)     smoke_warn "$label: catch-all answered HTTP $code instead of closing the connection" ;;
        *)     smoke_warn "$label: could not connect (curl exit $rc) — is nginx listening?" ;;
    esac
}
if systemctl is-active --quiet nginx 2>/dev/null; then
    if grep -qs "return 444" /etc/nginx/sites-enabled/default; then
        smoke_closed "Nginx HTTP"  "http://localhost"
        grep -qs "ssl_reject_handshake on" /etc/nginx/sites-enabled/default && smoke_closed "Nginx HTTPS" "https://localhost" "-k"
    else
        smoke_http "Nginx HTTP"  "http://localhost"  "ok"
    fi
    # Each site with a Let's Encrypt certificate, requested by its own name but sent to this server
    NGX_TLS_SITES=0
    for le_dir in /etc/letsencrypt/live/*/; do
        le_name=$(basename "$le_dir")
        [[ -f "$le_dir/fullchain.pem" ]] || continue
        grep -RqsF "$le_name" /etc/nginx/sites-enabled/ || continue   # -R: sites-enabled holds symlinks
        smoke_http "Nginx HTTPS $le_name" "https://$le_name/" "ok" "-k --noproxy $le_name --resolve $le_name:443:127.0.0.1"
        NGX_TLS_SITES=$((NGX_TLS_SITES + 1))
    done
    (( NGX_TLS_SITES > 0 )) || smoke_skip "Nginx HTTPS site with a Let's Encrypt certificate"
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
    # the password set by ubuntu_provision.sh (file readable by root/valkey only); empty if none is set.
    # valkey-cli reads it from REDISCLI_AUTH / VALKEYCLI_AUTH, so it is not on the command line
    VALKEY_AUTH=$(sed -n 's/^requirepass "\(.*\)"$/\1/p' /etc/valkey/valkey-auth.conf 2>/dev/null)
    if REDISCLI_AUTH="$VALKEY_AUTH" VALKEYCLI_AUTH="$VALKEY_AUTH" valkey-cli ping 2>/dev/null | grep -q "PONG"; then
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

# --- Wazuh Server (shown only when a server component is installed) ---
WAZUH_SERVER_PRESENT=n
for wz_unit in wazuh-manager wazuh-indexer wazuh-dashboard; do
    systemctl list-unit-files "${wz_unit}.service" 2>/dev/null | grep -q "${wz_unit}.service" && WAZUH_SERVER_PRESENT=y
done

if [[ "$WAZUH_SERVER_PRESENT" == "y" ]]; then
echo ""
echo "Wazuh Server"
echo "==========================================="

wz() {   # wz ok|warn|bad "label" "message"
    local c
    case "$1" in ok) c="$GREEN" ;; warn) c="$YELLOW" ;; *) c="$RED" ;; esac
    echo -e "  $2: ${c}$3${NC}"
}

# Versions and upgrade protection (an unplanned apt upgrade of one component breaks the others)
WZ_VER=$(/var/ossec/bin/wazuh-control info 2>/dev/null | sed -n 's/^WAZUH_VERSION="v\{0,1\}\(.*\)"$/\1/p' | head -1)
echo "  Version: ${WZ_VER:-unknown}"
WZ_HELD=$(apt-mark showhold 2>/dev/null)
for wz_pkg in wazuh-indexer wazuh-manager filebeat wazuh-dashboard; do
    dpkg -s "$wz_pkg" >/dev/null 2>&1 || continue
    wz_pv=$(dpkg-query -W -f='${Version}' "$wz_pkg" 2>/dev/null)
    if grep -qx "$wz_pkg" <<<"$WZ_HELD"; then
        wz ok "$wz_pkg $wz_pv" "[HELD]"
        continue
    fi
    # Not held. Also safe if no enabled apt source offers the package (Wazuh's recommended
    # "comment out wazuh.list"): then the only entry in apt's version table is the installed copy
    # (/var/lib/dpkg/status). Anything else — another source, or apt-cache output we cannot read — warns.
    wz_policy=$(apt-cache policy "$wz_pkg" 2>/dev/null)
    wz_sources=$(awk '/^ +Version table:/ {t=1; next} t && /^ +[0-9]+ (\/|[a-z]+:)/ {print $2}' <<<"$wz_policy" | sort -u)
    if grep -q '^ *Installed:' <<<"$wz_policy" && [[ "$wz_sources" == "/var/lib/dpkg/status" ]]; then
        wz ok "$wz_pkg $wz_pv" "[NOT HELD, but no enabled apt source offers it — repo disabled]"
    else
        wz warn "$wz_pkg $wz_pv" "[NOT HELD — unattended-upgrades can upgrade it on its own]"
    fi
done

# Memory: heap vs RAM, swap use of the indexer, kernel map count
WZ_RAM_MB=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
WZ_XMX=$(sed -n 's/^-Xmx\([0-9]\+[mMgG]\)$/\1/p' /etc/wazuh-indexer/jvm.options 2>/dev/null | head -1)
if [[ -n "$WZ_XMX" ]]; then
    case "${WZ_XMX: -1}" in g|G) WZ_HEAP_MB=$(( ${WZ_XMX%?} * 1024 )) ;; *) WZ_HEAP_MB=${WZ_XMX%?} ;; esac
    WZ_HEAP_PCT=$(( WZ_HEAP_MB * 100 / WZ_RAM_MB ))
    if (( WZ_HEAP_PCT > 55 )); then
        wz bad  "Indexer heap" "[${WZ_HEAP_MB} MB = ${WZ_HEAP_PCT}% of ${WZ_RAM_MB} MB RAM — above half of RAM]"
    elif (( WZ_HEAP_PCT < 25 )); then
        wz warn "Indexer heap" "[${WZ_HEAP_MB} MB = ${WZ_HEAP_PCT}% of ${WZ_RAM_MB} MB RAM — small; circuit_breaking_exception risk]"
    else
        wz ok   "Indexer heap" "[${WZ_HEAP_MB} MB = ${WZ_HEAP_PCT}% of ${WZ_RAM_MB} MB RAM]"
    fi
else
    wz warn "Indexer heap" "[could not read -Xmx from /etc/wazuh-indexer/jvm.options]"
fi
WZ_PID=$(systemctl show -p MainPID --value wazuh-indexer 2>/dev/null)
if [[ -n "$WZ_PID" && "$WZ_PID" != "0" && -r "/proc/$WZ_PID/status" ]]; then
    WZ_SWAP_KB=$(awk '/^VmSwap:/ {print $2}' "/proc/$WZ_PID/status")
    if (( ${WZ_SWAP_KB:-0} > 262144 )); then
        wz warn "Indexer swap use" "[$(( WZ_SWAP_KB / 1024 )) MB swapped out — memory pressure]"
    else
        wz ok   "Indexer swap use" "[$(( ${WZ_SWAP_KB:-0} / 1024 )) MB]"
    fi
fi
WZ_MAPS=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
if (( WZ_MAPS >= 262144 )); then wz ok "vm.max_map_count" "[$WZ_MAPS]"; else wz bad "vm.max_map_count" "[$WZ_MAPS — indexer needs >= 262144]"; fi

# Circuit breaker trips in the last 24 hours (the failure that makes the dashboard say "internal server error")
WZ_CB=$(journalctl -u wazuh-indexer -u wazuh-dashboard --since "24 hours ago" --no-pager -q 2>/dev/null | grep -c 'circuit_breaking_exception')
if (( ${WZ_CB:-0} > 0 )); then
    wz bad "circuit_breaking_exception, last 24h" "[${WZ_CB} — indexer heap exhausted: raise heap/RAM or reduce shards]"
else
    wz ok  "circuit_breaking_exception, last 24h" "[none]"
fi

# Exposure: the indexer must listen on loopback only
WZ_LISTEN=$(ss -H -ltn 'sport = :9200' 2>/dev/null | awk '{print $4}' | paste -sd' ' -)
if [[ -z "$WZ_LISTEN" ]]; then
    wz bad "Indexer listening (9200)" "[not listening]"
elif grep -qE '(^| )(0\.0\.0\.0|\*|\[::\]):9200' <<<"$WZ_LISTEN"; then
    wz bad "Indexer listening (9200)" "[$WZ_LISTEN — reachable beyond localhost]"
else
    wz ok  "Indexer listening (9200)" "[$WZ_LISTEN]"
fi

# Agent ports in UFW (informational: they are meant to be open for remote agents)
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    for wz_port in 1514 1515; do
        wz_rule=$(ufw status | grep -E "^${wz_port}(/tcp)?[[:space:]]+ALLOW" | awk '{print $NF}' | paste -sd',' -)
        if [[ -z "$wz_rule" ]]; then
            wz warn "Agent port ${wz_port}/tcp" "[not open in UFW — remote agents cannot connect]"
        elif [[ "$wz_rule" == *Anywhere* ]]; then
            wz warn "Agent port ${wz_port}/tcp" "[open to Anywhere]"
        else
            wz ok   "Agent port ${wz_port}/tcp" "[open to ${wz_rule}]"
        fi
    done
fi

# Manager daemons
if [[ -x /var/ossec/bin/wazuh-control ]]; then
    WZ_STATUS=$(/var/ossec/bin/wazuh-control status 2>/dev/null)
    WZ_DOWN=""
    for wz_d in wazuh-analysisd wazuh-remoted wazuh-db wazuh-modulesd wazuh-monitord wazuh-authd wazuh-apid; do
        grep -q "^${wz_d} is running" <<<"$WZ_STATUS" || WZ_DOWN="$WZ_DOWN $wz_d"
    done
    if [[ -z "$WZ_DOWN" ]]; then wz ok "Manager daemons" "[all core daemons running]"; else wz bad "Manager daemons" "[not running:${WZ_DOWN}]"; fi
fi

# Agents (local query, no API credentials needed)
if [[ -x /var/ossec/bin/agent_control ]]; then
    WZ_AGENTS=$(/var/ossec/bin/agent_control -l 2>/dev/null | grep -E '^[[:space:]]*ID:' | grep -vE '^[[:space:]]*ID: 000,')
    WZ_A_TOTAL=$(grep -c . <<<"$WZ_AGENTS"); [[ -z "$WZ_AGENTS" ]] && WZ_A_TOTAL=0
    WZ_A_ACTIVE=$(grep -c ', Active$' <<<"$WZ_AGENTS")
    WZ_A_DISC=$(grep -c ', Disconnected$' <<<"$WZ_AGENTS")
    WZ_A_NEVER=$(grep -c ', Never connected$' <<<"$WZ_AGENTS")
    if (( WZ_A_TOTAL == 0 )); then
        wz warn "Agents" "[none enrolled]"
    elif (( WZ_A_DISC + WZ_A_NEVER > 0 )); then
        wz warn "Agents" "[${WZ_A_TOTAL} enrolled: ${WZ_A_ACTIVE} active, ${WZ_A_DISC} disconnected, ${WZ_A_NEVER} never connected]"
        grep -E ', (Disconnected|Never connected)$' <<<"$WZ_AGENTS" | sed 's/^[[:space:]]*/      /'
    else
        wz ok "Agents" "[${WZ_A_TOTAL} enrolled, all active]"
    fi
fi

# Alert pipeline: alerts written by the manager, shipped by filebeat
WZ_ALERTS=/var/ossec/logs/alerts/alerts.json
if [[ -f "$WZ_ALERTS" ]]; then
    WZ_AGE_MIN=$(( ( $(date +%s) - $(stat -c %Y "$WZ_ALERTS") ) / 60 ))
    if (( WZ_AGE_MIN > 120 )); then wz warn "Last alert written" "[${WZ_AGE_MIN} min ago]"; else wz ok "Last alert written" "[${WZ_AGE_MIN} min ago]"; fi
fi
if command -v filebeat >/dev/null 2>&1 && systemctl is-active --quiet filebeat 2>/dev/null; then
    if timeout 30 filebeat test output 2>&1 | grep -q 'talk to server... OK'; then
        wz ok  "Filebeat -> indexer" "[connection and login OK]"
    else
        wz bad "Filebeat -> indexer" "[cannot talk to the indexer — keystore password or indexer down; alerts are not being indexed]"
    fi
fi

# Endpoints
WZ_DASH_PORT=$(sed -n 's/^server\.port:[[:space:]]*\([0-9]\{1,5\}\).*/\1/p' /etc/wazuh-dashboard/opensearch_dashboards.yml 2>/dev/null | head -1)
if systemctl is-active --quiet wazuh-dashboard 2>/dev/null; then
    if [[ -n "$WZ_DASH_PORT" ]]; then
        smoke_http "Wazuh Dashboard (port $WZ_DASH_PORT)" "https://127.0.0.1:${WZ_DASH_PORT}" "ok" "-k"
    else
        smoke_warn "Wazuh Dashboard: server.port not found in /etc/wazuh-dashboard/opensearch_dashboards.yml"
    fi
fi
systemctl is-active --quiet wazuh-indexer 2>/dev/null && smoke_http "Wazuh Indexer API" "https://127.0.0.1:9200" "401" "-k"
systemctl is-active --quiet wazuh-manager 2>/dev/null && smoke_http "Wazuh Manager API" "https://127.0.0.1:55000" "401" "-k"

# Cluster, shards, disk: need the read-only health user from utils/wazuh_server_tune.sh
WZ_CRED=/etc/wazuh-health.conf
WZ_USER=""; WZ_PASS=""; WZ_RET=""
if [[ -e "$WZ_CRED" ]]; then
    if [[ "$(stat -c '%U:%G %a' "$WZ_CRED")" == "root:root 600" ]]; then
        WZ_USER=$(sed -n 's/^WAZUH_HEALTH_USER=//p' "$WZ_CRED" | head -1)
        WZ_PASS=$(sed -n 's/^WAZUH_HEALTH_PASSWORD=//p' "$WZ_CRED" | head -1)
        WZ_RET=$(sed -n 's/^WAZUH_ALERTS_RETENTION_DAYS=//p' "$WZ_CRED" | head -1)
        [[ "$WZ_USER" =~ ^[A-Za-z0-9_.-]+$ && "$WZ_PASS" =~ ^[A-Za-z0-9]+$ ]] || { WZ_USER=""; WZ_PASS=""; wz bad "Health credentials" "[$WZ_CRED has an unusable user/password — ignored]"; }
        [[ "$WZ_RET" =~ ^[0-9]+$ ]] || WZ_RET=""
    else
        wz bad "Health credentials" "[$WZ_CRED must be owned by root with mode 600 — ignored]"
    fi
else
    wz warn "Cluster checks" "[skipped — no $WZ_CRED; create it: sudo WAZUH_CREATE_HEALTH_USER=y utils/wazuh_server_tune.sh]"
fi

if [[ -n "$WZ_USER" && -n "$WZ_PASS" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
        wz warn "Cluster checks" "[skipped — jq is not installed]"
    else
        WZ_CFG=$(mktemp); chmod 600 "$WZ_CFG"
        printf 'user = "%s:%s"\n' "$WZ_USER" "$WZ_PASS" > "$WZ_CFG"
        wz_api() { curl -sk --max-time 30 -K "$WZ_CFG" "https://127.0.0.1:9200$1" 2>/dev/null; }

        WZ_H=$(wz_api "/_cluster/health")
        if ! jq -e '.status' >/dev/null 2>&1 <<<"$WZ_H"; then
            wz bad "Cluster health" "[indexer unreachable or login rejected for $WZ_USER]"
        else
            WZ_ST=$(jq -r '.status' <<<"$WZ_H"); WZ_ACT=$(jq -r '.active_shards' <<<"$WZ_H")
            WZ_UNA=$(jq -r '.unassigned_shards' <<<"$WZ_H"); WZ_DN=$(jq -r '.number_of_data_nodes' <<<"$WZ_H")
            case "$WZ_ST" in
                green)  wz ok   "Cluster health" "[green — ${WZ_ACT} active shards]" ;;
                yellow) wz warn "Cluster health" "[yellow — ${WZ_UNA} unassigned shards (replicas on a single node are normal)]" ;;
                *)      wz bad  "Cluster health" "[${WZ_ST} — ${WZ_UNA} unassigned shards, some data is unavailable]" ;;
            esac

            # Shards against the per-node limit (new daily indices cannot be created once it is reached)
            WZ_LIMIT=$(wz_api "/_cluster/settings?include_defaults=true&flat_settings=true" \
                | jq -r '[.transient, .persistent, .defaults] | map(select(. != null) | ."cluster.max_shards_per_node") | map(select(. != null)) | .[0] // empty' 2>/dev/null)
            if [[ "$WZ_LIMIT" =~ ^[0-9]+$ && "$WZ_DN" =~ ^[0-9]+$ && "$WZ_DN" -gt 0 ]]; then
                WZ_MAX=$(( WZ_LIMIT * WZ_DN )); WZ_SH_PCT=$(( WZ_ACT * 100 / WZ_MAX ))
                if   (( WZ_SH_PCT >= 90 )); then wz bad  "Shards vs limit" "[${WZ_ACT} of ${WZ_MAX} (${WZ_SH_PCT}%) — new indices will fail soon]"
                elif (( WZ_SH_PCT >= 70 )); then wz warn "Shards vs limit" "[${WZ_ACT} of ${WZ_MAX} (${WZ_SH_PCT}%)]"
                else                             wz ok   "Shards vs limit" "[${WZ_ACT} of ${WZ_MAX} (${WZ_SH_PCT}%)]"; fi
            else
                wz warn "Shards vs limit" "[limit not readable — ${WZ_ACT} active shards]"
            fi

            # JVM heap and parent circuit breaker
            WZ_N=$(wz_api "/_nodes/stats/jvm,breaker?filter_path=nodes.*.jvm.mem.heap_used_percent,nodes.*.breakers.parent")
            WZ_HEAP_USED=$(jq -r '[.nodes[].jvm.mem.heap_used_percent] | max // empty' <<<"$WZ_N" 2>/dev/null)
            if [[ "$WZ_HEAP_USED" =~ ^[0-9]+$ ]]; then
                if   (( WZ_HEAP_USED >= 85 )); then wz bad  "JVM heap in use" "[${WZ_HEAP_USED}%]"
                elif (( WZ_HEAP_USED >= 75 )); then wz warn "JVM heap in use" "[${WZ_HEAP_USED}%]"
                else                                wz ok   "JVM heap in use" "[${WZ_HEAP_USED}%]"; fi
            fi
            WZ_TRIPPED=$(jq -r '[.nodes[].breakers.parent.tripped] | add // empty' <<<"$WZ_N" 2>/dev/null)
            if [[ "$WZ_TRIPPED" =~ ^[0-9]+$ ]]; then
                if (( WZ_TRIPPED > 0 )); then wz warn "Parent breaker trips since start" "[${WZ_TRIPPED}]"; else wz ok "Parent breaker trips since start" "[0]"; fi
            fi

            # Alert indices: size, shard sizing, age against retention
            WZ_I=$(wz_api "/_cat/indices/wazuh-alerts-*?h=index,pri,store.size,creation.date&bytes=b&format=json")
            if jq -e 'length > 0' >/dev/null 2>&1 <<<"$WZ_I"; then
                WZ_IDX_N=$(jq 'length' <<<"$WZ_I")
                WZ_IDX_PRI=$(jq '[.[] | .pri | tonumber] | add' <<<"$WZ_I")
                WZ_IDX_BYTES=$(jq '[.[] | ."store.size" | tonumber] | add' <<<"$WZ_I")
                WZ_OLDEST_MS=$(jq '[.[] | ."creation.date" | tonumber] | min' <<<"$WZ_I")
                WZ_OLDEST_DAYS=$(( ( $(date +%s) - WZ_OLDEST_MS / 1000 ) / 86400 ))
                WZ_AVG_SHARD_MB=$(( WZ_IDX_BYTES / WZ_IDX_PRI / 1048576 ))
                echo "  Alert indices: ${WZ_IDX_N} (${WZ_IDX_PRI} primary shards, $(( WZ_IDX_BYTES / 1073741824 )) GB), oldest ${WZ_OLDEST_DAYS} days"
                if (( WZ_IDX_PRI > 300 && WZ_AVG_SHARD_MB < 1024 )); then
                    wz warn "Shard sizing" "[average shard ${WZ_AVG_SHARD_MB} MB — many tiny shards cost heap; use fewer shards per index]"
                else
                    wz ok   "Shard sizing" "[average shard ${WZ_AVG_SHARD_MB} MB]"
                fi
                if [[ -n "$WZ_RET" && "$WZ_RET" != "0" ]]; then
                    if (( WZ_OLDEST_DAYS > WZ_RET + 2 )); then
                        wz warn "Alert retention ${WZ_RET} days" "[oldest index is ${WZ_OLDEST_DAYS} days — policy not attached to older indices]"
                    else
                        wz ok   "Alert retention ${WZ_RET} days" "[oldest index ${WZ_OLDEST_DAYS} days]"
                    fi
                else
                    wz warn "Alert retention" "[none configured — indices grow until the disk is full]"
                fi
            fi
            WZ_TPL=$(wz_api "/_template/wazuh?filter_path=wazuh.settings.index.number_of_shards" | jq -r '.wazuh.settings.index.number_of_shards // empty' 2>/dev/null)
            [[ -n "$WZ_TPL" ]] && echo "  New alert indices get ${WZ_TPL} primary shard(s)"
        fi
        rm -f "$WZ_CFG"
    fi
fi

# Indexer data disk (no credentials needed). OpenSearch stops allocating at 85%, goes read-only at 95%.
WZ_DISK_PCT=$(df --output=pcent /var/lib/wazuh-indexer 2>/dev/null | tail -n1 | tr -dc '0-9')
if [[ -n "$WZ_DISK_PCT" ]]; then
    if   (( WZ_DISK_PCT >= 90 )); then wz bad  "Indexer data disk" "[${WZ_DISK_PCT}% full — allocation watermarks reached]"
    elif (( WZ_DISK_PCT >= 80 )); then wz warn "Indexer data disk" "[${WZ_DISK_PCT}% full]"
    else                               wz ok   "Indexer data disk" "[${WZ_DISK_PCT}% full]"; fi
fi
fi

echo ""
