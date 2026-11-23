#!/bin/bash
#
# UBUNTU SERVER INCIDENT RESPONSE SCRIPT
# Identification, triage, containment, investigation and evidence export for a server set up with
# ubuntu_provision.sh (nginx, MySQL/MariaDB, Suricata, Forgejo, Wazuh agent, auditd, gunicorn web apps
# in /home/xlvisuals/<domain>/ with their secrets in /etc/xlvisuals/<domain_with_underscores>.env).
# by Xlvisuals Limited + Claude
# 23 November 2026
#
# Procedure around it: howto/howto-incident-response.md
#
# -----------------------------------------------------------------------------------------
#
# Usage: sudo bash ubuntu_incident_response.sh <command> [options]
#
# Commands (in the usual order):
#   triage              Quick read-only check (1-3 min). Prints HIGH/MED/INFO findings.
#   collect             Evidence, most volatile first: processes, network, sessions, then logs, configs,
#                       web apps, file system timeline. Read-only apart from writing the case directory.
#   investigate         Deeper read-only checks: package and virtualenv integrity, changed files, logins,
#                       sudo, nginx logs, Suricata, auditd, MySQL accounts, Forgejo users/keys/hooks.
#   secrets             Rotation checklist for the rebuild: names and paths only, never values.
#   contain <action>    Changes the server, asks first. Actions:
#                         network       allow only SSH from --admin-ip (+ Wazuh manager), drop the rest,
#                                       kill other established connections
#                         undo-network  restore the firewall saved by 'contain network'
#                         webapps       freeze the gunicorn services (keeps memory; --stop to stop them)
#                         undo-webapps  thaw the frozen services
#                         user NAME     lock an account, disable its SSH keys, end its sessions
#                         cron          stop cron and atd (persistence that re-triggers)
#                         status        show what is contained
#   export              Pack the case directory: tar.gz + sha256 (+ GPG encryption with --encrypt-to).
#   all                 triage, collect, investigate, secrets, export (never contains).
#
# Options:
#   --case DIR          Case directory. Default: the newest case under /root/ir, or a new one.
#   --new-case          Start a new case directory even if one exists.
#   --since DAYS        Look-back window for changed files, logins and logs (default 14).
#   --app-root DIR      Parent directory of the web apps (default /home/xlvisuals).
#   --env-dir DIR       Directory with the web app .env files (default /etc/xlvisuals).
#   --admin-ip LIST     Comma-separated IPs/CIDRs you administer from. Required for 'contain network';
#                       in triage/investigate, SSH logins from other addresses are flagged HIGH.
#   --console           You have the provider's console: allow 'contain' actions that could cut off
#                       your own SSH session.
#   --wazuh-manager H   'contain network': manager to keep reachable (default: read from ossec.conf).
#   --keep-connections  'contain network': do not kill established connections.
#   --stop              'contain webapps': stop instead of freeze.
#   --include-secrets   'collect': also copy files that hold secrets and process environments
#                       (default: only their path, owner, mode, times and sha256).
#   --max-log-mb N      'collect': copy single log files up to N MB (default 1024); bigger ones are
#                       listed with their sha256.
#   --no-timeline       'collect': skip the file system timeline (bodyfile).
#   --encrypt-to FILE   'export': encrypt to this GPG public key file; aborts if that fails.
#   --yes               'contain': do not ask for confirmation (input is still checked).
#
# Fails closed: missing or invalid input aborts instead of guessing; 'contain network' refuses to run
# without --admin-ip that covers your current SSH address; secrets stay out of the evidence unless
# --include-secrets is given; a requested encryption that fails leaves no plaintext archive behind.
#
# Run a copy from your workstation (scp), not the copy on the server: an attacker with root can
# change any file there. Check its sha256 after copying. See the howto.

set -uo pipefail
export LC_ALL=C
umask 077
# System directories only: /usr/local/* is not owned by any package and an easy place to plant a tool.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset LD_PRELOAD LD_LIBRARY_PATH BASH_ENV ENV PYTHONPATH PYTHONHOME PYTHONSTARTUP GIT_DIR GIT_WORK_TREE

SCRIPT_VERSION="2026-11-23"
SCRIPT_PATH="$(readlink -f -- "$0" 2>/dev/null || echo "$0")"

## Defaults
## --------------------------------------------
IR_BASE="/root/ir"
APP_ROOT="/home/xlvisuals"
ENV_DIR="/etc/xlvisuals"
SINCE_DAYS=14
ADMIN_IPS=""
CONSOLE="n"
WAZUH_MANAGER_ARG=""
KEEP_CONNECTIONS="n"
STOP_APPS="n"
INCLUDE_SECRETS="n"
MAX_LOG_MB=1024
MAX_APP_FILE_MB=50
MAX_EXE_MB=200
TIMELINE="y"
ENCRYPT_TO=""
ASSUME_YES="n"
CASE_ARG=""
NEW_CASE="n"
CMD_TIMEOUT=300
LONG_TIMEOUT=3600
# Public listeners that are expected on this stack (port/proto). Override with IR_EXPECTED_PORTS.
EXPECTED_PUBLIC_PORTS="${IR_EXPECTED_PORTS:-22/tcp 80/tcp 443/tcp 443/udp 68/udp 7881/tcp 3478/udp}"
# Outbound ports that are normal for this stack (web APIs, DNS, NTP, mail relay, Wazuh).
NORMAL_OUT_PORTS="${IR_NORMAL_OUT_PORTS:-53 80 123 443 465 587 1514 1515}"

# Shell one-liners that are typical for droppers, reverse shells and miners
SUSP_RX='(curl|wget)[^#]*\|[[:space:]]*(ba|da|z)?sh|base64[[:space:]]+(-d|--decode)|/dev/tcp/|/dev/udp/|bash[[:space:]]+-i|nc(at)?[[:space:]]+[^|]*-[ec][[:space:]]|socat[[:space:]]|python[0-9.]*[[:space:]]+-c[[:space:]]|perl[[:space:]]+-e|/dev/shm/|mkfifo|xmrig|stratum\+tcp|chattr[[:space:]]+\+i'

COMMAND=""
SUBARG=""
PHASE=""
CASE=""
HIGH_COUNT=0
MED_COUNT=0
HOST="$(hostname -s 2>/dev/null || echo host)"
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; GREEN=$'\033[0;32m'; GREY=$'\033[0;37m'
    BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=""; YELLOW=""; GREEN=""; GREY=""; BOLD=""; NC=""
fi

## Helpers
## --------------------------------------------

usage() { sed -n '14,62p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'; }

die() {
    printf '  %s[X]%s %s\n' "$RED" "$NC" "$*" >&2
    [[ -n "$CASE" && -f "$CASE/case.log" ]] && log_case "ABORT $*"
    exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }
utc() { date -u +%FT%TZ; }

log_case() { printf '%s %s\n' "$(utc)" "$*" >> "$CASE/case.log"; }

section() { printf '\n%s== %s ==%s\n' "$BOLD" "$*" "$NC"; }
note()    { printf '  %s\n' "$*"; }
ok()      { printf '  %s[V]%s %s\n' "$GREEN" "$NC" "$*"; }

# finding LEVEL message   (LEVEL = HIGH | MED | INFO)
finding() {
    local lvl="$1" c; shift
    printf '%s [%s] [%s] %s\n' "$(utc)" "$PHASE" "$lvl" "$*" >> "$CASE/findings.txt"
    case "$lvl" in
        HIGH) c="$RED" ;;
        MED)  c="$YELLOW" ;;
        *)    c="$GREY" ;;
    esac
    printf '  %s[%s]%s %s\n' "$c" "$lvl" "$NC" "$*"
}

# Findings are counted from findings.txt: finding() often runs inside a pipeline (a subshell)
FIND_START=0
phase_begin() {
    PHASE="$1"
    FIND_START="$(wc -l < "$CASE/findings.txt")"
    log_case "PHASE $1"
}
phase_counts() {
    HIGH_COUNT="$(tail -n +$((FIND_START + 1)) "$CASE/findings.txt" | grep -c '] \[HIGH\] ')"
    MED_COUNT="$(tail -n +$((FIND_START + 1)) "$CASE/findings.txt" | grep -c '] \[MED\] ')"
}

# cap OUTFILE cmd args...   - runs an external command with a timeout, output + header into OUTFILE
cap() {
    local out="$1" rc; shift
    mkdir -p -- "$(dirname -- "$out")"
    {
        printf '# %s\n# started %s\n' "$*" "$(utc)"
        timeout "$CMD_TIMEOUT" "$@" 2>&1
        rc=$?
        printf '# exit %s\n' "$rc"
    } >> "$out"
}

# capsh OUTFILE 'shell pipeline'   - fixed pipelines written in this script only (never user data)
capsh() {
    local out="$1"; shift
    cap "$out" bash -c "$1"
}

# confirm "question"  - fails closed: anything but y/yes is no
confirm() {
    [[ "$ASSUME_YES" == "y" ]] && return 0
    [[ -t 0 ]] || die "No terminal to ask '$1'. Re-run interactively or with --yes."
    local a
    read -rp "  $1 (y/n) [n]: " a
    [[ "${a,,}" == "y" || "${a,,}" == "yes" ]]
}

# changed within the window (ctime: also changes when someone resets mtime with touch)
recent() { [[ -e "$1" ]] && [[ -n "$(find "$1" -maxdepth 0 -cmin "-$((SINCE_DAYS * 1440))" 2>/dev/null)" ]]; }

since_iso() { date -u -d "-${SINCE_DAYS} days" +%Y-%m-%d; }

file_meta() {   # path -> "owner:group mode size mtime ctime sha256 path"
    local f="$1" h
    h="$(sha256sum -- "$f" 2>/dev/null | awk '{print $1}')"
    stat -c "%U:%G %a %s mtime=%y ctime=%z ${h:-unreadable} %n" -- "$f" 2>/dev/null
}

slugify() { local s="${1,,}"; s="${s//./_}"; s="${s//-/_}"; printf '%s' "$s"; }

is_loopback() { [[ "$1" == 127.* || "$1" == "::1" || "$1" == "[::1]" || "$1" == ::ffff:127.* ]]; }

## Validation
## --------------------------------------------

valid_abs_path() {
    [[ "$1" == /* && "$1" != *$'\n'* && "$1" != *'/../'* && "$1" != */.. && "$1" =~ ^[A-Za-z0-9._/@:+-]+$ ]]
}

# Every element must be an IPv4/IPv6 address or CIDR (checked with python's ipaddress, no shell parsing)
valid_ip_list() {
    [[ -n "$1" ]] || return 1
    python3 -I -c '
import ipaddress, sys
items = [x.strip() for x in sys.argv[1].split(",")]
if not items or any(not x for x in items): sys.exit(1)
for x in items:
    try: ipaddress.ip_network(x, strict=False)
    except ValueError: sys.exit(1)
' "$1"
}

# ip_in_list IP LIST  -> 0 if IP is inside one of the networks
ip_in_list() {
    python3 -I -c '
import ipaddress, sys
try: ip = ipaddress.ip_address(sys.argv[1].strip("[]").split("%")[0])
except ValueError: sys.exit(1)
if ip.version == 6 and ip.ipv4_mapped: ip = ip.ipv4_mapped
for x in sys.argv[2].split(","):
    n = ipaddress.ip_network(x.strip(), strict=False)
    if ip.version == n.version and ip in n: sys.exit(0)
sys.exit(1)
' "$1" "$2"
}

## Arguments
## --------------------------------------------

parse_args() {
    [[ $# -gt 0 ]] || { usage; exit 2; }
    COMMAND="$1"; shift
    case "$COMMAND" in
        triage|collect|investigate|secrets|export|all) ;;
        contain)
            [[ $# -gt 0 && "$1" != --* ]] || die "contain needs an action: network | undo-network | webapps | undo-webapps | user NAME | cron | status"
            SUBARG="$1"; shift
            if [[ "$SUBARG" == "user" ]]; then
                [[ $# -gt 0 && "$1" != --* ]] || die "contain user needs a user name."
                SUBARG="user:$1"; shift
            fi
            ;;
        -h|--help|help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --case)            CASE_ARG="${2:-}"; shift 2 ;;
            --new-case)        NEW_CASE="y"; shift ;;
            --since)           SINCE_DAYS="${2:-}"; shift 2 ;;
            --app-root)        APP_ROOT="${2:-}"; shift 2 ;;
            --env-dir)         ENV_DIR="${2:-}"; shift 2 ;;
            --admin-ip)        ADMIN_IPS="${2:-}"; shift 2 ;;
            --console)         CONSOLE="y"; shift ;;
            --wazuh-manager)   WAZUH_MANAGER_ARG="${2:-}"; shift 2 ;;
            --keep-connections) KEEP_CONNECTIONS="y"; shift ;;
            --stop)            STOP_APPS="y"; shift ;;
            --include-secrets) INCLUDE_SECRETS="y"; shift ;;
            --max-log-mb)      MAX_LOG_MB="${2:-}"; shift 2 ;;
            --no-timeline)     TIMELINE="n"; shift ;;
            --encrypt-to)      ENCRYPT_TO="${2:-}"; shift 2 ;;
            --yes)             ASSUME_YES="y"; shift ;;
            *) die "Unknown option '$1' (see --help)." ;;
        esac
    done
    [[ "$SINCE_DAYS" =~ ^[1-9][0-9]{0,3}$ ]] || die "--since must be a number of days (1-9999)."
    [[ "$MAX_LOG_MB" =~ ^[1-9][0-9]{0,6}$ ]] || die "--max-log-mb must be a positive number."
    valid_abs_path "$APP_ROOT" || die "--app-root must be an absolute path."
    valid_abs_path "$ENV_DIR"  || die "--env-dir must be an absolute path."
    [[ -z "$CASE_ARG" ]] || valid_abs_path "$CASE_ARG" || die "--case must be an absolute path (letters, digits, ._/-)."
    if [[ -n "$ADMIN_IPS" ]]; then valid_ip_list "$ADMIN_IPS" || die "--admin-ip must be a comma-separated list of IP addresses or CIDRs."; fi
    if [[ -n "$WAZUH_MANAGER_ARG" ]]; then
        [[ "$WAZUH_MANAGER_ARG" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || die "--wazuh-manager must be a host name or IP."
    fi
    if [[ -n "$ENCRYPT_TO" ]]; then
        [[ -f "$ENCRYPT_TO" && -r "$ENCRYPT_TO" ]] || die "--encrypt-to: key file '$ENCRYPT_TO' not found or not readable."
    fi
}

## Case directory
## --------------------------------------------

init_case() {
    local c=""
    if [[ -n "$CASE_ARG" ]]; then
        c="$CASE_ARG"
    elif [[ "$NEW_CASE" != "y" && -d "$IR_BASE" ]]; then
        c="$(find "$IR_BASE" -mindepth 2 -maxdepth 2 -name .ir_case -printf '%T@ %h\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
    fi
    [[ -n "$c" ]] || c="$IR_BASE/${HOST}_${RUN_TS}"
    c="${c%/}"
    case "$c" in
        /|/proc*|/sys*|/dev*|/run*|/etc*|/usr*|/bin*|/sbin*|/lib*|/boot*) die "Case directory '$c' is not allowed." ;;
    esac
    [[ "$c/" == "$APP_ROOT/"* ]] && die "Case directory must not be inside the web app directory $APP_ROOT."
    if [[ -e "$c" ]]; then
        [[ -d "$c" && ! -L "$c" ]] || die "'$c' exists and is not a directory."
        if [[ ! -f "$c/.ir_case" ]]; then
            [[ -z "$(ls -A -- "$c")" ]] || die "'$c' exists, is not empty and is not a case directory (.ir_case missing)."
        fi
    fi
    mkdir -p -m 700 -- "$c" || die "Cannot create $c"
    chown root:root -- "$c" && chmod 700 -- "$c"
    CASE="$c"
    touch "$CASE/findings.txt" "$CASE/case.log"
    if [[ ! -f "$CASE/.ir_case" ]]; then
        printf 'host=%s\ncreated=%s\nscript_version=%s\n' "$(hostname -f 2>/dev/null || hostname)" "$(utc)" "$SCRIPT_VERSION" > "$CASE/.ir_case"
        cat > "$CASE/README.txt" <<EOF
Incident response case directory for $(hostname -f 2>/dev/null || hostname), created $(utc)
by ubuntu_incident_response.sh ($SCRIPT_VERSION).

case.log          chain of custody: who ran what, when, from where; manifest hashes
findings.txt      HIGH / MED / INFO findings of triage and investigate
MANIFEST.sha256   sha256 of every file in this directory (refreshed after every command)
triage/ volatile/ logs/ config/ apps/ timeline/ investigate/ secrets/ containment/

Times are UTC. Shell histories are included and may contain secrets typed on the command line.
Secret-bearing files are NOT included unless --include-secrets was used; config/secrets_manifest.txt
lists their path, owner, mode, times and sha256 so they can be compared with a backup.
EOF
    fi
    log_case "START command=$COMMAND${SUBARG:+ $SUBARG} operator=${SUDO_USER:-root} ssh_client=${SSH_CLIENT:-none} script=$SCRIPT_PATH sha256=$(sha256sum -- "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}') since_days=$SINCE_DAYS app_root=$APP_ROOT env_dir=$ENV_DIR"
    note "Case directory: $CASE"
}

refresh_manifest() {
    ( cd "$CASE" && find . -type f ! -name 'MANIFEST.sha256*' ! -name case.log ! -name .ir_case -print0 | sort -z | xargs -0 -r sha256sum ) > "$CASE/MANIFEST.sha256.tmp" 2>/dev/null
    mv -f "$CASE/MANIFEST.sha256.tmp" "$CASE/MANIFEST.sha256"
    log_case "MANIFEST $(sha256sum "$CASE/MANIFEST.sha256" | awk '{print $1}') files=$(wc -l < "$CASE/MANIFEST.sha256")"
}

## Discovery
## --------------------------------------------

APPS=()        # domain directory names under APP_ROOT
discover_apps() {
    APPS=()
    [[ -d "$APP_ROOT" ]] || return 0
    local d n
    for d in "$APP_ROOT"/*/; do
        [[ -d "$d" && ! -L "${d%/}" ]] || continue
        n="$(basename -- "$d")"
        [[ "$n" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || continue
        APPS+=("$n")
    done
}

# app_units DOMAIN -> systemd unit names that run this app (by name, or by referencing its directory)
app_units() {
    local dom="$1" slug f
    slug="$(slugify "$dom")"
    {
        [[ -f "/etc/systemd/system/$slug.service" ]] && echo "$slug.service"
        grep -l -F -- "$APP_ROOT/$dom/" /etc/systemd/system/*.service 2>/dev/null | while read -r f; do basename -- "$f"; done
        grep -l -E -- "$APP_ROOT/$dom([[:space:]]|\$)" /etc/systemd/system/*.service 2>/dev/null | while read -r f; do basename -- "$f"; done
    } | sort -u
}

# unit_user UNIT -> the account the unit runs as. No User= means root (fail closed: unknown counts as root).
unit_user() {
    local u
    u="$(systemctl show -p User --value "$1" 2>/dev/null)"
    if [[ -z "$u" ]]; then
        u="$(sed -n 's/^[[:space:]]*User=[[:space:]]*//p' "/etc/systemd/system/$1" /etc/systemd/system/"$1".d/*.conf 2>/dev/null | tail -1)"
    fi
    printf '%s' "${u:-root}"
}

# unit_pids UNIT -> all PIDs in the unit's cgroup (cgroup v2)
unit_pids() {
    local cg
    cg="$(systemctl show -p ControlGroup --value "$1" 2>/dev/null)"
    [[ -n "$cg" && -d "/sys/fs/cgroup$cg" ]] || return 0
    find "/sys/fs/cgroup$cg" -name cgroup.procs -exec cat {} + 2>/dev/null
}

# All web app units (one per line)
all_app_units() {
    local a
    for a in "${APPS[@]}"; do app_units "$a"; done | sort -u
}

wazuh_manager() {
    if [[ -n "$WAZUH_MANAGER_ARG" ]]; then printf '%s' "$WAZUH_MANAGER_ARG"; return; fi
    [[ -f /var/ossec/etc/ossec.conf ]] || return 0
    sed -n 's:.*<address>\([^<]*\)</address>.*:\1:p' /var/ossec/etc/ossec.conf | head -1
}

# home directories of all accounts that have one (plus root)
homes() {
    awk -F: '$6 ~ /^\// && $6 != "/" && $6 != "/nonexistent" {print $1":"$6}' /etc/passwd | sort -u
}

# auth log lines (current + rotated) - falls back to the journal when rsyslog files are missing
auth_lines() {
    local f found=n
    for f in /var/log/auth.log /var/log/auth.log.1 /var/log/auth.log.*.gz; do
        [[ -f "$f" ]] || continue
        found=y
        if [[ "$f" == *.gz ]]; then zcat -- "$f" 2>/dev/null; else cat -- "$f"; fi
    done
    if [[ "$found" == "n" ]]; then
        journalctl --since "-${SINCE_DAYS} days" -o short-iso --no-pager _TRANSPORT=syslog 2>/dev/null
        journalctl --since "-${SINCE_DAYS} days" -o short-iso --no-pager -t sshd -t sshd-session -t sudo 2>/dev/null
    fi
}

## TRIAGE
## --------------------------------------------

t_host() {
    section "Host"
    local d="$CASE/triage"
    mkdir -p "$d"
    note "$(hostname -f 2>/dev/null || hostname)  kernel $(uname -r)  up since $(uptime -s 2>/dev/null)  server time $(date '+%F %T %Z')  UTC $(utc)"
    [[ "$(date +%Z)" == "UTC" ]] || finding INFO "Server time zone is $(date +%Z), not UTC: convert log times before comparing with other sources."
    cap "$d/who.txt" who -a
    cap "$d/w.txt" w
    cap "$d/last.txt" last -F -w -n 200
    local sessions
    sessions="$(who | awk '{print $1" "$NF}' | sort -u | tr '\n' ' ')"
    note "Logged in now: ${sessions:-nobody}"
}

t_accounts() {
    section "Accounts"
    local u
    while IFS=: read -r u _ uid _; do
        [[ "$uid" == "0" && "$u" != "root" ]] && finding HIGH "Account '$u' has UID 0 (root)."
    done < /etc/passwd
    awk -F: '($2 == "") {print $1}' /etc/shadow 2>/dev/null | while read -r u; do
        finding HIGH "Account '$u' has an empty password field (login without password)."
    done
    local shells
    shells="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false|sync)$/ {printf "%s ", $1}' /etc/passwd)"
    finding INFO "Accounts with a login shell (UID>=1000): ${shells:-none}"
    local sys_shell
    sys_shell="$(awk -F: '$3 > 0 && $3 < 1000 && $7 !~ /(nologin|false|sync)$/ {printf "%s(%s) ", $1, $7}' /etc/passwd)"
    [[ -n "$sys_shell" ]] && finding MED "System accounts with a login shell: $sys_shell(git for Forgejo is expected)"
    local admins
    admins="$(getent group sudo admin wheel 2>/dev/null | awk -F: '{print $1": "$4}' | tr '\n' ' ')"
    finding INFO "Admin groups: ${admins:-none}"
    for f in /etc/passwd /etc/shadow /etc/group /etc/gshadow; do
        recent "$f" && finding MED "$f changed in the last $SINCE_DAYS days ($(stat -c %z "$f")). Check for new accounts or password changes."
    done
}

t_ssh() {
    section "SSH"
    local d="$CASE/triage" line key val
    if have sshd; then
        sshd -T 2>/dev/null > "$d/sshd_T.txt"
        while read -r key val; do
            case "$key" in
                passwordauthentication|kbdinteractiveauthentication|permitemptypasswords)
                    [[ "$val" == "no" ]] || finding HIGH "sshd: $key $val (key-only login was configured by the provisioning)." ;;
                permitrootlogin)
                    [[ "$val" == "no" ]] || finding HIGH "sshd: permitrootlogin $val." ;;
                authorizedkeyscommand)
                    [[ "$val" == "none" ]] || finding HIGH "sshd: authorizedkeyscommand $val (keys can come from a program)." ;;
                authorizedkeysfile)
                    [[ "$val" == ".ssh/authorized_keys .ssh/authorized_keys2" || "$val" == ".ssh/authorized_keys" ]] \
                        || finding MED "sshd: authorizedkeysfile is '$val' (non-standard: check those files too)." ;;
            esac
        done < "$d/sshd_T.txt"
    fi
    [[ -e /etc/ssh/sshrc ]] && finding MED "/etc/ssh/sshrc exists: runs at every SSH login."
    for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*; do
        [[ -f "$f" ]] && recent "$f" && finding MED "$f changed in the last $SINCE_DAYS days."
    done

    # authorized_keys of every account
    local user home ak n
    : > "$d/authorized_keys.txt"
    while IFS=: read -r user home; do
        for ak in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
            [[ -f "$ak" ]] || continue
            n="$(grep -c -E '^[^#[:space:]]' "$ak" 2>/dev/null)"
            { echo "## $ak ($user) $(stat -c '%U:%G %a mtime=%y ctime=%z' "$ak")"; ssh-keygen -lf "$ak" 2>&1; grep -n -E '^[^#]*(command=|environment=|from=)' "$ak"; } >> "$d/authorized_keys.txt"
            if [[ "$user" == "root" && "$n" -gt 0 ]]; then
                finding MED "root has $n SSH key(s) in $ak (root login is disabled, but this is a ready backdoor)."
            fi
            [[ "$user" == "git" ]] && continue   # managed by Forgejo; checked in investigate
            recent "$ak" && finding MED "$ak ($n keys) changed in the last $SINCE_DAYS days. Compare with the keys you know: triage/authorized_keys.txt"
        done
        [[ -e "$home/.ssh/rc" ]] && finding MED "$home/.ssh/rc exists: runs at every SSH login of $user."
    done < <(homes)

    # successful logins
    local since
    since="$(since_iso)"
    auth_lines | grep -E 'sshd(-session)?\[[0-9]+\]: Accepted ' \
        | awk -v since="$since" '
            { ts=$1; if (ts ~ /^[0-9]{4}-/ && substr(ts,1,10) < since) next
              for (i=1;i<=NF;i++) if ($i=="Accepted") { m=$(i+1); u=$(i+3); ip=$(i+5) }
              k=m" "u" "ip; c[k]++; if (!(k in first)) first[k]=ts; last[k]=ts }
            END { for (k in c) print k, c[k], first[k], last[k] }' \
        | sort > "$d/ssh_logins.txt"
    local method luser ip count first lastts
    while read -r method luser ip count first lastts; do
        [[ -n "$method" ]] || continue
        if [[ "$method" != "publickey" ]]; then
            finding HIGH "SSH login with $method: $luser from $ip ($count times, $first .. $lastts)."
        elif [[ -n "$ADMIN_IPS" ]] && ! ip_in_list "$ip" "$ADMIN_IPS"; then
            finding HIGH "SSH login from an address outside --admin-ip: $luser from $ip ($count times, $first .. $lastts)."
        else
            finding INFO "SSH logins: $luser from $ip ($count times, $first .. $lastts)."
        fi
    done < "$d/ssh_logins.txt"
    [[ -s "$d/ssh_logins.txt" ]] || finding MED "No successful SSH logins found in the auth logs, not even yours: logs rotated away, or removed."
}

t_sudo() {
    section "sudo"
    local f
    for f in /etc/sudoers /etc/sudoers.d/*; do
        [[ -f "$f" ]] || continue
        recent "$f" && finding MED "$f changed in the last $SINCE_DAYS days."
        grep -H -n -E '^[^#]*NOPASSWD:[[:space:]]*ALL([[:space:]]|$)' "$f" 2>/dev/null | while read -r line; do
            finding HIGH "Unrestricted passwordless sudo: $line"
        done
    done
    # Web app service users with sudo rights: an app compromise is then a root compromise
    local unit user
    while read -r unit; do
        [[ -n "$unit" ]] || continue
        user="$(unit_user "$unit")"
        if [[ "$user" == "root" ]]; then
            finding HIGH "Web app $unit runs as root: any code execution in the app is root."
            continue
        fi
        if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel'; then
            finding HIGH "Web app $unit runs as '$user', who is in the sudo group: treat an app compromise as a root compromise."
        elif sudo -l -U "$user" 2>/dev/null | grep -q NOPASSWD; then
            finding HIGH "Web app $unit runs as '$user', who has NOPASSWD sudo rules ($(sudo -l -U "$user" 2>/dev/null | grep NOPASSWD | head -1 | sed 's/^[[:space:]]*//')). NOPASSWD systemctl is root-equivalent."
        fi
    done < <(all_app_units)
}

t_preload() {
    section "Loader and shell start-up"
    if [[ -s /etc/ld.so.preload ]]; then
        finding HIGH "/etc/ld.so.preload is not empty (classic userland rootkit): $(head -c 300 /etc/ld.so.preload | tr '\n' ' ')"
    fi
    local f
    for f in /etc/profile /etc/bash.bashrc /etc/environment /etc/profile.d/* /root/.bashrc /root/.profile; do
        [[ -f "$f" ]] || continue
        grep -q -E "$SUSP_RX" "$f" 2>/dev/null && finding HIGH "Suspicious command in $f: $(grep -m1 -E "$SUSP_RX" "$f" | cut -c1-200)"
        grep -q -E '(HISTFILE=/dev/null|unset[[:space:]]+HISTFILE|HISTSIZE=0|HISTFILESIZE=0)' "$f" 2>/dev/null && finding HIGH "Shell history disabled in $f."
        recent "$f" && finding MED "$f changed in the last $SINCE_DAYS days."
    done
    local user home h
    while IFS=: read -r user home; do
        for h in "$home/.bash_history" "$home/.zsh_history" "$home/.mysql_history"; do
            [[ -L "$h" ]] && finding HIGH "$h is a symlink to $(readlink "$h") (history suppressed)."
        done
        for f in "$home/.bashrc" "$home/.profile" "$home/.bash_profile" "$home/.bash_logout"; do
            [[ -f "$f" ]] || continue
            grep -q -E "$SUSP_RX" "$f" 2>/dev/null && finding HIGH "Suspicious command in $f: $(grep -m1 -E "$SUSP_RX" "$f" | cut -c1-200)"
            grep -q -E '(HISTFILE=/dev/null|unset[[:space:]]+HISTFILE|HISTSIZE=0)' "$f" 2>/dev/null && finding HIGH "Shell history disabled in $f."
        done
    done < <(homes)
}

t_processes() {
    section "Processes"
    local d="$CASE/triage" p exe path comm cmd
    cap "$d/ps.txt" ps -eo pid,ppid,user,lstart,pcpu,pmem,stat,args --forest
    declare -A deleted_other=()
    for p in /proc/[0-9]*; do
        p="${p#/proc/}"
        exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || continue
        [[ -n "$exe" ]] || continue
        comm="$(cat "/proc/$p/comm" 2>/dev/null)"
        cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-200)"
        path="${exe% (deleted)}"
        if [[ "$exe" == /memfd:* || "$exe" == memfd:* ]]; then
            finding HIGH "PID $p ($comm) runs from memory (memfd): $cmd"
        elif [[ "$path" == /tmp/* || "$path" == /var/tmp/* || "$path" == /dev/shm/* || "$path" == /run/shm/* || "$path" == /run/user/* ]]; then
            finding HIGH "PID $p ($comm) runs from a temp directory: $exe  [$cmd]"
        elif [[ "$exe" == *" (deleted)" ]]; then
            if [[ "$path" == /home/* || "$path" == /root/* || "$path" == /var/* || "$path" == /opt/* || "$path" == /srv/* ]]; then
                finding HIGH "PID $p ($comm) runs a deleted program outside the system directories: $exe  [$cmd]"
            else
                deleted_other["$path"]+="$p "
            fi
        elif [[ "$path" == /home/* || "$path" == /root/* ]]; then
            finding MED "PID $p ($comm) runs a program from a home directory: $exe  [$cmd]"
        fi
        if [[ "$cmd" == \[* ]]; then
            finding HIGH "PID $p pretends to be a kernel thread ('$cmd') but has a program file: $exe"
        fi
    done
    for path in "${!deleted_other[@]}"; do
        finding MED "Deleted program still running: $path (PIDs ${deleted_other[$path]}). Usually a package upgrade without restart (needrestart); compare with dpkg -S."
    done

    # what the web apps, nginx, MySQL and Forgejo have started
    local unit pid c hi='^(nc|ncat|netcat|socat|curl|wget|perl|php|ruby|telnet|ssh|scp|sftp|base64|nohup|xmrig|python[0-9.]*|busybox|tmux|screen)$' sh='^(sh|bash|dash|zsh|ksh)$'
    local units
    units="$(all_app_units; systemctl list-units --type=service --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -E '^(nginx|mysql|mariadb|forgejo|postgresql@?.*)\.service$')"
    while read -r unit; do
        [[ -n "$unit" ]] || continue
        while read -r pid; do
            [[ -n "$pid" ]] || continue
            c="$(cat "/proc/$pid/comm" 2>/dev/null)" || continue
            cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-200)"
            case "$unit" in
                forgejo.service)
                    [[ "$c" =~ ^(nc|ncat|netcat|socat|curl|wget|perl|php|ruby|telnet|xmrig|busybox)$ ]] && finding HIGH "Forgejo started '$c' (PID $pid): $cmd" ;;
                nginx.service|mysql.service|mariadb.service|postgresql*)
                    [[ "$c" =~ $hi || "$c" =~ $sh ]] && finding HIGH "$unit started '$c' (PID $pid): $cmd" ;;
                *)
                    # the app itself is python/gunicorn: only flag python started with -c, or other tools
                    if [[ "$c" =~ ^python ]]; then
                        [[ "$cmd" =~ (^|[[:space:]])-c[[:space:]] ]] && finding HIGH "Web app $unit runs 'python -c' (PID $pid): $cmd"
                    elif [[ "$c" =~ $hi ]]; then
                        finding HIGH "Web app $unit started '$c' (PID $pid): $cmd"
                    elif [[ "$c" =~ $sh ]]; then
                        finding MED "Web app $unit started a shell (PID $pid): $cmd  (expected only if the app calls subprocess with shell=True)"
                    fi ;;
            esac
        done < <(unit_pids "$unit")
    done <<< "$units"

    # CPU hogs (miners)
    ps -eo pid=,user=,pcpu=,comm= --sort=-pcpu 2>/dev/null | head -5 | while read -r pid user cpu c; do
        awk -v c="$cpu" 'BEGIN{exit !(c > 80)}' || continue
        [[ "$c" =~ ^(mysqld|mariadbd|gunicorn|python.*|suricata|Suricata-Main|W#.*|nginx|wazuh.*|forgejo|aide|find|dpkg|apt.*|sha256sum|tar|gzip|unattended-upgr.*|ps)$ ]] && continue
        finding MED "PID $pid ($c, user $user) uses ${cpu}% CPU."
    done
}

t_network() {
    section "Network"
    local d="$CASE/triage"
    have ss || { finding INFO "ss not available: network checks skipped."; return; }
    cap "$d/ss_listen.txt" ss -tulpnH
    cap "$d/ss_established.txt" ss -tunpH state established
    local livekit=n
    systemctl cat livekit.service >/dev/null 2>&1 && livekit=y
    declare -A listen_ports=()
    local net state rq sq local_ peer proc addr port
    while read -r net state rq sq local_ peer proc; do
        [[ -n "$local_" ]] || continue
        port="${local_##*:}"; addr="${local_%:*}"; addr="${addr%%%*}"
        listen_ports["$port"]=1
        is_loopback "$addr" && continue
        [[ "$addr" == "127.0.0.53" || "$addr" == "127.0.0.54" ]] && continue
        [[ " $EXPECTED_PUBLIC_PORTS " == *" $port/$net "* ]] && continue
        [[ "$livekit" == "y" && "$net" == "udp" && "$port" =~ ^[0-9]+$ && "$port" -ge 50000 ]] && continue
        finding MED "Unexpected public listener $net $local_ $proc"
    done < <(ss -tulpnH 2>/dev/null)

    local lport pport paddr
    while read -r net rq sq local_ peer proc; do
        [[ -n "$peer" ]] || continue
        lport="${local_##*:}"; pport="${peer##*:}"; paddr="${peer%:*}"
        is_loopback "$paddr" && continue
        [[ -n "${listen_ports[$lport]:-}" ]] && continue            # inbound to one of our services
        [[ " $NORMAL_OUT_PORTS " == *" $pport "* ]] && continue
        finding MED "Outbound connection to $peer from $local_ $proc"
    done < <(ss -tunpH state established 2>/dev/null)
    if have ufw; then
        ufw status 2>/dev/null | head -1 | grep -q 'Status: active' || finding HIGH "UFW firewall is not active."
    fi
}

t_cron() {
    section "Scheduled jobs"
    local f
    for f in /etc/crontab /etc/cron.d/* /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/* /var/spool/cron/crontabs/* /var/spool/cron/atjobs/*; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" == .placeholder ]] && continue
        grep -q -E "$SUSP_RX" "$f" 2>/dev/null && finding HIGH "Suspicious command in $f: $(grep -m1 -E "$SUSP_RX" "$f" | cut -c1-200)"
        recent "$f" && finding MED "$f changed in the last $SINCE_DAYS days."
    done
    for f in /var/spool/cron/crontabs/*; do
        [[ -f "$f" ]] && finding INFO "User crontab: $(basename "$f") ($(grep -c -E '^[^#[:space:]]' "$f") entries)"
    done
    for f in /var/spool/cron/atjobs/*; do
        [[ -f "$f" && "$(basename "$f")" != .SEQ ]] && finding MED "at job present: $f"
    done
}

t_systemd() {
    section "systemd units"
    local f
    while IFS= read -r -d '' f; do
        grep -q -E "$SUSP_RX" "$f" 2>/dev/null && finding HIGH "Suspicious command in unit $f: $(grep -m1 -E "$SUSP_RX" "$f" | cut -c1-200)"
        grep -q -E '^[[:space:]]*Exec[A-Za-z]*=.*(/tmp/|/var/tmp/|/dev/shm/)' "$f" 2>/dev/null && finding HIGH "Unit $f runs something from a temp directory."
        recent "$f" && finding MED "Unit file $f changed in the last $SINCE_DAYS days."
    done < <(find /etc/systemd/system /etc/systemd/user /usr/local/lib/systemd -type f \( -name '*.service' -o -name '*.timer' -o -name '*.path' -o -name '*.socket' -o -name '*.conf' \) -print0 2>/dev/null)
    local user home
    while IFS=: read -r user home; do
        [[ -d "$home/.config/systemd/user" ]] && finding MED "User systemd units for $user: $(find "$home/.config/systemd/user" -type f -printf '%f ' 2>/dev/null)"
    done < <(homes)
    for f in /etc/systemd/system-generators/* /usr/local/lib/systemd/system-generators/*; do
        [[ -L "$f" && "$(readlink "$f")" == /dev/null ]] && continue     # a generator disabled by the admin
        [[ -e "$f" ]] && finding HIGH "systemd generator present (runs at every boot/daemon-reload): $f"
    done
    [[ -s /etc/rc.local ]] && finding MED "/etc/rc.local exists: $(grep -v -E '^#|^$|^exit 0' /etc/rc.local | head -3 | tr '\n' ';')"
}

t_tmp() {
    section "Temp directories"
    local f n=0
    while IFS= read -r -d '' f; do
        n=$((n + 1)); [[ $n -gt 2000 ]] && break
        if [[ -x "$f" ]] || [[ "$(head -c 4 -- "$f" 2>/dev/null | tr -d '\0')" == $'\x7fELF' ]]; then
            finding HIGH "Executable or ELF file in a temp directory: $(stat -c '%U %a %s %y' -- "$f") $f"
        fi
    done < <(find /tmp /var/tmp /dev/shm -type f -print0 2>/dev/null)
    find /tmp /var/tmp /dev/shm -mindepth 1 -maxdepth 3 -name '.*' ! -name '.X11-unix' ! -name '.ICE-unix' ! -name '.font-unix' ! -name '.XIM-unix' ! -name '.Test-unix' 2>/dev/null | head -20 | while read -r f; do
        finding MED "Hidden entry in a temp directory: $f"
    done
}

t_kernel() {
    section "Kernel"
    local t
    t="$(cat /proc/sys/kernel/tainted 2>/dev/null || echo 0)"
    if [[ "$t" != "0" ]]; then
        local bits=""
        (( t & 1 ))    && bits+="P(proprietary) "
        (( t & 4096 )) && bits+="O(out-of-tree module) "
        (( t & 8192 )) && bits+="E(unsigned module) "
        (( t & 32768 )) && bits+="K(livepatch) "
        if (( (t & 4096) || (t & 8192) )); then
            finding MED "Kernel tainted=$t ${bits}: a module not shipped with the kernel was loaded."
        else
            finding INFO "Kernel tainted=$t $bits"
        fi
    fi
    local m fn kdir
    kdir="/lib/modules/$(uname -r)"
    while read -r m _; do
        fn="$(modinfo -F filename "$m" 2>/dev/null)"
        if [[ -z "$fn" ]]; then
            finding MED "Loaded module '$m' has no module file (in-memory or removed)."
        elif [[ "$fn" != "$kdir"/* && "$fn" != "/usr$kdir"/* && "$fn" != "(builtin)" ]]; then
            finding MED "Loaded module '$m' comes from outside $kdir: $fn"
        fi
    done < <(cat /proc/modules 2>/dev/null)
}

t_security_services() {
    section "Security and logging services"
    local s
    for s in auditd wazuh-agent suricata fail2ban apparmor cron rsyslog systemd-journald ssh; do
        systemctl list-unit-files "$s.service" --no-legend 2>/dev/null | grep -q "^$s.service" || [[ -f "/lib/systemd/system/$s.service" || -f "/usr/lib/systemd/system/$s.service" ]] || continue
        if systemctl is-active --quiet "$s"; then
            ok "$s running"
        else
            finding HIGH "$s is not running ($(systemctl is-active "$s" 2>/dev/null)). Attackers stop monitoring first; see 'journalctl -u $s'."
        fi
    done
    if have auditctl; then
        auditctl -s 2>/dev/null | grep -q '^enabled 0' && finding HIGH "auditd is not enabled in the kernel (auditctl -s: enabled 0)."
        [[ "$(auditctl -l 2>/dev/null | grep -vc '^No rules')" -lt 5 ]] && finding HIGH "auditd has (almost) no rules loaded."
    fi
    if [[ -f /var/ossec/var/run/wazuh-agentd.state ]]; then
        grep -q "status='connected'" /var/ossec/var/run/wazuh-agentd.state \
            && ok "Wazuh agent connected to the manager" \
            || finding MED "Wazuh agent is not connected to the manager: $(grep -E '^status' /var/ossec/var/run/wazuh-agentd.state)"
    fi
    local f
    for f in /var/log/auth.log /var/log/syslog /var/log/wtmp; do
        if [[ ! -e "$f" ]]; then finding HIGH "$f is missing."
        elif [[ ! -s "$f" ]]; then finding MED "$f is empty (just rotated, or wiped)."
        fi
    done
    [[ -e /var/log/btmp && -s /var/log/btmp ]] || finding INFO "/var/log/btmp is empty or missing (failed logins)."
}

t_webapps() {
    section "Web apps in $APP_ROOT"
    [[ ${#APPS[@]} -gt 0 ]] || { finding INFO "No web app directories found in $APP_ROOT."; return; }
    local a slug dir unit env f n st owner mode
    for a in "${APPS[@]}"; do
        slug="$(slugify "$a")"; dir="$APP_ROOT/$a"
        note "${BOLD}$a${NC}"
        local units
        units="$(app_units "$a" | tr '\n' ' ')"
        [[ -n "$units" ]] || finding INFO "$a: no systemd unit found (/etc/systemd/system/$slug.service)."
        for unit in $units; do
            note "  unit $unit: $(systemctl is-active "$unit" 2>/dev/null), user $(unit_user "$unit")"
        done
        # env files: the slug file plus any EnvironmentFile= of its units
        local envs=("$ENV_DIR/$slug.env") e
        for unit in $units; do
            local tok
            while read -r e; do
                for tok in ${e#*=}; do
                    tok="${tok#-}"
                    [[ -n "$tok" && "$tok" != "${envs[0]}" ]] && envs+=("$tok")
                done
            done < <(systemctl cat "$unit" 2>/dev/null | grep -E '^[[:space:]]*EnvironmentFile=')
        done
        for env in "${envs[@]}"; do
            if [[ ! -e "$env" ]]; then
                [[ "$env" == "${envs[0]}" ]] && finding INFO "$a: $env not found."
                continue
            fi
            st="$(stat -c '%U %G %a' -- "$env")"; read -r owner _ mode <<< "$st"
            [[ "$owner" == "root" ]] || finding HIGH "$a: $env is owned by '$owner', not root."
            (( 8#$mode & 8#007 )) && finding HIGH "$a: $env is readable or writable by everyone (mode $mode)."
            (( 8#$mode & 8#020 )) && finding HIGH "$a: $env is group-writable (mode $mode)."
            recent "$env" && finding MED "$a: $env changed in the last $SINCE_DAYS days ($(stat -c %z -- "$env"))."
            [[ "$env" == "$dir"/* ]] && finding MED "$a: env file $env is inside the app directory (readable by the app user)."
        done
        # secrets lying around in the app directory
        find "$dir" -maxdepth 3 \( -name '.env' -o -name '*.env' \) -type f ! -path '*/venv/*' 2>/dev/null | head -5 | while read -r f; do
            finding MED "$a: env file inside the app directory: $f ($(stat -c '%U %a' -- "$f"))"
        done
        # changed code (outside venv/logs)
        n="$(find "$dir" \( -name venv -o -name .venv -o -name node_modules -o -name .git -o -name __pycache__ -o -name log \) -prune -o -type f \( -name '*.py' -o -name '*.sh' -o -name '*.js' -o -name '*.html' \) -cmin "-$((SINCE_DAYS * 1440))" -print 2>/dev/null | wc -l)"
        [[ "$n" -gt 0 ]] && finding MED "$a: $n code files changed in the last $SINCE_DAYS days (expected after a deployment; 'investigate' lists them)."
        # executable content where only data or static files belong
        find "$dir" \( -name venv -o -name .venv -o -name node_modules -o -name .git \) -prune -o -type f \( -path '*/static/*' -o -path '*/upload*' -o -path '*/media/*' -o -path '*/files/*' \) \
            \( -iname '*.py' -o -iname '*.pyc' -o -iname '*.sh' -o -iname '*.php*' -o -iname '*.phtml' -o -iname '*.pl' -o -iname '*.cgi' -o -iname '*.so' -o -iname '*.jsp' \) -print 2>/dev/null | head -20 | while read -r f; do
            finding HIGH "$a: script/program file in a static/upload directory: $f ($(stat -c '%U %a %y' -- "$f"))"
        done
        n="$(find "$dir" \( -name venv -o -name .venv -o -name node_modules -o -name .git \) -prune -o -type f \( -path '*/static/*' -o -path '*/upload*' -o -path '*/media/*' \) -perm -u+x -print 2>/dev/null | wc -l)"
        [[ "$n" -gt 0 ]] && finding MED "$a: $n files with the execute bit in static/upload directories (often harmless copies; check for ELF/scripts)."
        if [[ -d "$dir/.git" ]]; then
            n="$(safe_git "$dir" status --porcelain 2>/dev/null | wc -l)"
            [[ "$n" -gt 0 ]] && finding MED "$a: git working tree has $n changed/untracked files (see investigate/apps/$a/git_status.txt)."
        fi
    done
}

# git without anything the repository can configure to run (fsmonitor, hooks, pager, diff drivers);
# run as the owner of the directory, never as root.
safe_git() {
    local dir="$1" owner; shift
    owner="$(stat -c %U -- "$dir")"
    [[ "$owner" != "root" ]] || return 1
    have git || return 1
    runuser -u "$owner" -- env -i PATH=/usr/bin:/bin HOME=/nonexistent GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
        timeout 120 git -C "$dir" -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.pager=cat -c diff.external= \
        -c safe.directory="$dir" --no-pager "$@"
}

t_core_packages() {
    section "Integrity of core packages"
    have dpkg || return
    local pkgs=() p
    for p in openssh-server openssh-client sudo sudo-rs passwd login libpam-modules libpam-modules-bin libpam-runtime libpam0g \
             coreutils procps iproute2 net-tools util-linux findutils grep sed gawk mawk systemd cron bash dash libc6 libc-bin \
             auditd openssl curl wget nginx nginx-common lsof psmisc kmod; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' && pkgs+=("$p")
    done
    dpkg --verify "${pkgs[@]}" > "$CASE/triage/dpkg_verify_core.txt" 2>&1
    parse_dpkg_verify "$CASE/triage/dpkg_verify_core.txt"
}

# dpkg --verify lines: "??5??????   /path" (changed content), "??5?????? c /etc/x" (conffile), "missing   /path"
# Missing docs/man pages are normal (minimized images exclude them); missing programs are not.
parse_dpkg_verify() {
    local line flags attr path conf=0 miss=0
    while IFS= read -r line; do
        if [[ "$line" == missing* ]]; then
            path="${line##* }"; miss=$((miss + 1))
            case "$path" in
                /usr/bin/*|/usr/sbin/*|/bin/*|/sbin/*|*/security/*|/etc/pam.d/*|/usr/lib/systemd/system/*|/lib/systemd/system/*)
                    [[ -d "$path" ]] || finding MED "Package program/PAM/unit file missing: $path" ;;
            esac
            continue
        fi
        [[ ${#line} -gt 12 ]] || continue
        flags="${line:0:9}"; attr="${line:10:1}"; path="${line:12}"
        [[ "$flags" =~ ^[?.0-9A-Za-z]{9}$ ]] || continue
        if [[ "$attr" == "c" ]]; then conf=$((conf + 1)); continue; fi
        [[ "${flags:2:1}" == "5" ]] || continue
        case "$path" in
            /usr/bin/*|/usr/sbin/*|/bin/*|/sbin/*|*/security/*|*.so|*.so.*|/lib/modules/*|/usr/lib/modules/*|/boot/*|/usr/lib/systemd/*|/lib/systemd/*|/usr/libexec/*|/usr/lib/openssh/*)
                finding HIGH "Package program/library changed: $path ($(dpkg -S "$path" 2>/dev/null | cut -d: -f1)). Replaced binaries are a rootkit sign." ;;
            *)
                finding MED "Package file changed: $path ($(dpkg -S "$path" 2>/dev/null | cut -d: -f1))." ;;
        esac
    done < "$1"
    [[ $miss -gt 0 ]] && finding INFO "$miss package files missing, mostly docs/man pages excluded on minimized images (listed in $(basename "$1"))."
    [[ $conf -gt 0 ]] && finding INFO "$conf changed configuration files (normal after provisioning; listed in $(basename "$1"))."
}

do_triage() {
    phase_begin triage
    mkdir -p "$CASE/triage"
    t_host; t_accounts; t_ssh; t_sudo; t_preload; t_processes; t_network; t_cron; t_systemd; t_tmp; t_kernel
    t_security_services; t_webapps; t_core_packages
    phase_counts
    section "Triage result"
    if [[ $HIGH_COUNT -gt 0 ]]; then
        printf '  %s%d HIGH%s and %d MED findings. Treat this as an incident: take a provider snapshot, then collect and contain (see the howto).\n' "$RED" "$HIGH_COUNT" "$NC" "$MED_COUNT"
    elif [[ $MED_COUNT -gt 0 ]]; then
        printf '  %s%d MED%s findings, no HIGH. Check each one; if any is unexplained, continue with collect and investigate.\n' "$YELLOW" "$MED_COUNT" "$NC"
    else
        printf '  %sNo HIGH or MED findings.%s A clean triage does not rule out a compromise (root can hide); check the Wazuh manager too.\n' "$GREEN" "$NC"
    fi
    log_case "TRIAGE high=$HIGH_COUNT med=$MED_COUNT"
}

## COLLECT
## --------------------------------------------

# Files that hold secrets. Relative to / (tar -C /). Left out unless --include-secrets.
secret_excludes() {
    local e="${ENV_DIR#/}"
    printf '%s\n' \
        etc/shadow etc/shadow- etc/gshadow etc/gshadow- etc/security/opasswd \
        'etc/ssh/ssh_host_*_key' etc/ssl/private \
        etc/letsencrypt/archive etc/letsencrypt/keys etc/letsencrypt/accounts 'etc/letsencrypt/live/*/privkey.pem' 'etc/letsencrypt/*.ini' \
        "$e" etc/postfix/sasl_passwd 'etc/postfix/sasl_passwd.*' etc/monit/monitrc 'etc/monit/conf.d/*' etc/mysql/debian.cnf \
        etc/forgejo/app.ini etc/grafana/grafana.ini etc/livekit etc/valkey/valkey.conf etc/redis/redis.conf 'etc/mosquitto/passwd*' \
        etc/landscape/client.conf etc/webmin etc/wireguard etc/ipsec.secrets 'etc/ppp/*secrets' \
        'var/ossec/etc/client.keys' 'var/ossec/etc/authd.pass' 'var/ossec/etc/sslmanager.key' \
        '*.key' '*.env' '*.p12' '*.pfx' '*.jks' '*privkey*' '*secret*' '*credentials*'
}

collect_volatile() {
    section "Volatile data (processes, network, sessions)"
    local d="$CASE/volatile"
    mkdir -p "$d/proc" "$d/exe"
    cap "$d/date.txt" date -u
    cap "$d/uptime.txt" uptime
    cap "$d/who.txt" who -a
    cap "$d/w.txt" w
    cap "$d/loginctl.txt" loginctl list-sessions --no-legend
    cap "$d/ps_forest.txt" ps -eo pid,ppid,pgid,sid,uid,user,lstart,etimes,pcpu,pmem,rss,stat,tty,args --forest
    cap "$d/ps_threads.txt" ps -eLo pid,tid,user,comm
    have ss && { cap "$d/ss_all.txt" ss -tunapeH; cap "$d/ss_unix.txt" ss -xapH; cap "$d/ss_summary.txt" ss -s; }
    have lsof && cap "$d/lsof.txt" lsof -nP
    cap "$d/ip_addr.txt" ip -d addr
    cap "$d/ip_route.txt" ip route show table all
    cap "$d/ip_rule.txt" ip rule
    cap "$d/ip_neigh.txt" ip neigh
    have iptables-save && cap "$d/iptables.txt" iptables-save -c
    have ip6tables-save && cap "$d/ip6tables.txt" ip6tables-save -c
    have nft && cap "$d/nft.txt" nft list ruleset
    have ipset && capsh "$d/ipset.txt" 'ipset list -n; ipset list -t'
    have ufw && cap "$d/ufw.txt" ufw status verbose
    have conntrack && cap "$d/conntrack.txt" conntrack -L
    cap "$d/lsmod.txt" lsmod
    cap "$d/proc_modules.txt" cat /proc/modules
    cap "$d/tainted.txt" cat /proc/sys/kernel/tainted
    cap "$d/mounts.txt" cat /proc/mounts
    cap "$d/df.txt" df -hT
    cap "$d/free.txt" free -m
    cap "$d/dmesg.txt" dmesg -T
    cap "$d/systemctl_units.txt" systemctl list-units --all --no-pager
    cap "$d/systemctl_failed.txt" systemctl --failed --no-pager
    cap "$d/systemctl_timers.txt" systemctl list-timers --all --no-pager
    cap "$d/unit_files.txt" systemctl list-unit-files --no-pager
    cap "$d/resolv.txt" cat /etc/resolv.conf /etc/hosts
    have resolvectl && cap "$d/resolvectl.txt" resolvectl status
    have fail2ban-client && capsh "$d/fail2ban.txt" 'fail2ban-client status; fail2ban-client status sshd'

    # per process: program, command line, working dir, open files, maps of deleted libraries
    local p exe dst sz n=0 cmdl
    : > "$d/proc/processes.tsv"; : > "$d/proc/exe_sha256.txt"; : > "$d/proc/deleted_maps.txt"; : > "$d/proc/fds.txt"
    declare -A seen=()
    for p in /proc/[0-9]*; do
        p="${p#/proc/}"
        exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || continue
        cmdl="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
        printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$(stat -c %U "/proc/$p" 2>/dev/null)" "$exe" "$(readlink "/proc/$p/cwd" 2>/dev/null)" "$cmdl" >> "$d/proc/processes.tsv"
        { echo "## $p $exe"; ls -l "/proc/$p/fd" 2>/dev/null | awk 'NR>1 {print $NF}' | sort | uniq -c | sort -rn | head -50; } >> "$d/proc/fds.txt"
        grep ' (deleted)' "/proc/$p/maps" 2>/dev/null | awk -v p="$p" '{print p, $NF, $(NF-1)}' | sort -u >> "$d/proc/deleted_maps.txt"
        if [[ "$INCLUDE_SECRETS" == "y" ]]; then
            { echo "## $p $exe"; tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null; } >> "$d/proc/environ_SECRETS.txt"
        fi
        # hash each program once (reading /proc/PID/exe also works for deleted files)
        if [[ -z "${seen[$exe]:-}" ]]; then
            seen["$exe"]=1
            printf '%s  %s (pid %s)\n' "$(sha256sum "/proc/$p/exe" 2>/dev/null | awk '{print $1}')" "$exe" "$p" >> "$d/proc/exe_sha256.txt"
            # keep a copy of programs that are deleted or run from temp/home/memfd: often the malware itself
            if [[ "$exe" == *" (deleted)" || "$exe" == *memfd:* || "$exe" == /tmp/* || "$exe" == /var/tmp/* || "$exe" == /dev/shm/* || "$exe" == /home/* || "$exe" == /root/* ]]; then
                sz="$(stat -L -c %s "/proc/$p/exe" 2>/dev/null || echo 0)"
                if [[ "$sz" -le $((MAX_EXE_MB * 1024 * 1024)) && $n -lt 50 ]]; then
                    dst="$d/exe/${p}_$(basename -- "${exe% (deleted)}" | tr -c 'A-Za-z0-9._-' '_').bin"
                    cp -- "/proc/$p/exe" "$dst" 2>/dev/null && chmod 400 "$dst" && n=$((n + 1))
                fi
            fi
        fi
    done
    [[ $n -gt 0 ]] && note "Copied $n suspicious program(s) to volatile/exe/ (mode 400, do not run them)."
    ok "volatile data saved"
}

collect_logs() {
    section "Logs"
    local d="$CASE/logs" list="$CASE/logs/.filelist" big="$CASE/logs/skipped_large_files.txt"
    mkdir -p "$d"
    : > "$big"
    local roots=(/var/log /var/ossec/logs /var/lib/forgejo/log) a
    for a in "${APPS[@]}"; do [[ -d "$APP_ROOT/$a/log" ]] && roots+=("$APP_ROOT/$a/log"); done
    find "${roots[@]}" -type f -size "-$((MAX_LOG_MB + 1))M" -print0 2>/dev/null > "$list"
    find "${roots[@]}" -type f -size "+${MAX_LOG_MB}M" -print 2>/dev/null | while read -r f; do file_meta "$f" >> "$big"; done
    tar --null -T "$list" -czf "$d/logs.tar.gz" --ignore-failed-read --warning=no-file-changed 2>> "$d/tar_errors.txt"
    rm -f -- "$list"
    note "logs.tar.gz: $(du -h "$d/logs.tar.gz" | cut -f1)  (large files not copied: $(wc -l < "$big"), see skipped_large_files.txt)"
    capsh "$d/journal_${SINCE_DAYS}d.txt.gz.log" "journalctl --since '-${SINCE_DAYS} days' -o short-iso-precise --no-pager | gzip > '$d/journal_${SINCE_DAYS}d.txt.gz'"
    # shell histories of all accounts (key evidence; may contain secrets typed on the command line)
    local user home h
    mkdir -p "$d/history"
    while IFS=: read -r user home; do
        for h in .bash_history .zsh_history .python_history .mysql_history .psql_history .lesshst .viminfo .wget-hsts .sqlite_history; do
            [[ -f "$home/$h" && ! -L "$home/$h" ]] && cp -p -- "$home/$h" "$d/history/${user}_${h#.}"
        done
    done < <(homes)
    cap "$d/lastlog.txt" lastlog
    cap "$d/last.txt" last -F -w -x
    cap "$d/lastb.txt" lastb -F -w
    ok "logs saved"
}

collect_config() {
    section "Configuration"
    local d="$CASE/config"
    mkdir -p "$d"
    local excl=() e
    if [[ "$INCLUDE_SECRETS" != "y" ]]; then
        while read -r e; do excl+=(--exclude="$e"); done < <(secret_excludes)
    fi
    # /etc, crontabs, Wazuh agent config, and the scripts (not big binaries like forgejo) in /usr/local
    ( cd / && { find etc var/spool/cron var/ossec/etc usr/local/lib/systemd \( -type f -o -type l \) -print0 2>/dev/null
                find usr/local/bin usr/local/sbin \( -type f -size -1024k -o -type l \) -print0 2>/dev/null; } ) > "$d/.filelist"
    tar -C / "${excl[@]}" --null -T "$d/.filelist" -czf "$d/etc.tar.gz" --ignore-failed-read --warning=no-file-changed 2>> "$d/tar_errors.txt"
    rm -f -- "$d/.filelist"
    find /usr/local -xdev -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum > "$d/usr_local.sha256" 2>/dev/null
    # what was left out: path + metadata + hash, for comparison with a known-good backup
    if [[ "$INCLUDE_SECRETS" != "y" ]]; then
        { echo "# secret-bearing files left out of etc.tar.gz: owner:group mode size mtime ctime sha256 path"
          comm -23 <(cd / && find etc var/spool/cron var/ossec/etc usr/local/lib/systemd -type f 2>/dev/null | sort) \
                   <(tar -tzf "$d/etc.tar.gz" 2>/dev/null | sort) | while read -r e; do file_meta "/$e"; done
        } > "$d/secrets_manifest.txt"
        local a
        for a in "${APPS[@]}"; do find "$APP_ROOT/$a" -maxdepth 4 \( -name '.env' -o -name '*.env' \) -type f ! -path '*/venv/*' 2>/dev/null; done \
            | while read -r e; do file_meta "$e"; done >> "$d/secrets_manifest.txt"
        note "Secret-bearing files not copied: $(($(wc -l < "$d/secrets_manifest.txt") - 1)) (metadata + sha256 in config/secrets_manifest.txt)"
    else
        mkdir -p "$d/SECRETS"
        [[ -d "$ENV_DIR" ]] && cp -a -- "$ENV_DIR" "$d/SECRETS/"
        note "--include-secrets: secret files ARE in this case. Handle the export like the secrets themselves."
    fi
    # dotfiles and SSH metadata of all accounts (no private keys)
    local user home f
    mkdir -p "$d/home"
    while IFS=: read -r user home; do
        for f in .bashrc .profile .bash_profile .bash_logout .gitconfig .ssh/authorized_keys .ssh/authorized_keys2 .ssh/config .ssh/known_hosts .ssh/rc .config/systemd; do
            if [[ -e "$home/$f" ]]; then
                mkdir -p "$d/home/$user/$(dirname "$f")"
                cp -a -- "$home/$f" "$d/home/$user/$f" 2>/dev/null
            fi
        done
        find "$home/.ssh" -maxdepth 1 -type f 2>/dev/null | while read -r f; do file_meta "$f"; done > "$d/home/${user}_ssh_files.txt" 2>/dev/null
        [[ -s "$d/home/${user}_ssh_files.txt" ]] || rm -f "$d/home/${user}_ssh_files.txt"
    done < <(homes)
    have nginx && cap "$d/nginx_T.txt" nginx -T
    have sshd && cap "$d/sshd_T.txt" sshd -T
    have auditctl && { cap "$d/auditctl_l.txt" auditctl -l; cap "$d/auditctl_s.txt" auditctl -s; }
    have aa-status && cap "$d/apparmor.txt" aa-status
    cap "$d/packages.txt" dpkg -l
    cap "$d/apt_history.txt" bash -c 'cat /var/log/apt/history.log; zcat /var/log/apt/history.log.*.gz 2>/dev/null'
    have pip3 && cap "$d/pip_system.txt" pip3 list --path /usr/local/lib/python3/dist-packages
    cap "$d/crontabs.txt" bash -c 'for u in $(cut -d: -f1 /etc/passwd); do c=$(crontab -l -u "$u" 2>/dev/null) && printf "## %s\n%s\n" "$u" "$c"; done'
    ok "configuration saved"
}

collect_apps() {
    section "Web apps"
    local a dir out list
    for a in "${APPS[@]}"; do
        dir="$APP_ROOT/$a"; out="$CASE/apps/$a"
        mkdir -p "$out"
        list="$out/.filelist"
        # code and data, without virtualenvs, git objects, logs (in logs/) and secrets; files over the size limit listed
        find "$dir" \( -name venv -o -name .venv -o -name node_modules -o -name .git -o -name __pycache__ -o -path "$dir/log" \) -prune \
            -o -type f ! -name '*.sock' ! -name '*.pid' ! -name '.env' ! -name '*.env' -size "-$((MAX_APP_FILE_MB + 1))M" -print0 2>/dev/null > "$list"
        tar --null -T "$list" -czf "$out/files.tar.gz" --ignore-failed-read --warning=no-file-changed 2>> "$out/tar_errors.txt"
        rm -f -- "$list"
        find "$dir" \( -name venv -o -name .venv -o -name node_modules -o -name .git \) -prune -o -type f -size "+${MAX_APP_FILE_MB}M" -print 2>/dev/null \
            | while read -r f; do file_meta "$f"; done > "$out/skipped_large_files.txt"
        # hash of every file including venv and .git: compare with a clean deployment later
        find "$dir" -type f ! -name '*.sock' -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum > "$out/all_files.sha256" 2>/dev/null
        find "$dir" -printf '%M %u:%g %s mtime=%TY-%Tm-%Td_%TH:%TM ctime=%CY-%Cm-%Cd_%CH:%CM %p\n' 2>/dev/null > "$out/listing.txt"
        local unit
        for unit in $(app_units "$a"); do
            cap "$out/unit_$unit.txt" systemctl cat "$unit"
            cap "$out/unit_${unit}_status.txt" systemctl status --no-pager -l "$unit"
        done
        if [[ -d "$dir/.git" ]]; then
            { echo "# git status / log (run as $(stat -c %U "$dir"), repository config that runs programs disabled)"
              safe_git "$dir" status --porcelain=v1 --untracked-files=all
              echo "## log"; safe_git "$dir" log -n 50 --format='%H %ci %an <%ae> %s'
              echo "## remotes"; safe_git "$dir" remote -v
              echo "## diff --stat"; safe_git "$dir" diff --no-ext-diff --no-textconv --stat HEAD
            } > "$out/git_status.txt" 2>&1
            safe_git "$dir" diff --no-ext-diff --no-textconv HEAD > "$out/git_diff.patch" 2>/dev/null
        fi
        note "$a: $(du -h "$out/files.tar.gz" | cut -f1), $(wc -l < "$out/all_files.sha256") files hashed"
    done
    [[ ${#APPS[@]} -gt 0 ]] && ok "web apps saved"
}

collect_timeline() {
    section "File system timeline (bodyfile)"
    [[ "$TIMELINE" == "y" ]] || { note "skipped (--no-timeline)"; return; }
    local d="$CASE/timeline" mnt
    mkdir -p "$d"
    note "Walking all local file systems; this can take several minutes ..."
    # bodyfile format (Sleuth Kit mactime): MD5|name|inode|mode|UID|GID|size|atime|mtime|ctime|crtime
    while read -r mnt; do
        timeout "$LONG_TIMEOUT" find "$mnt" -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path "$IR_BASE" -o -path "$CASE" \) -prune \
            -o -printf '0|%p|%i|%M|%U|%G|%s|%A@|%T@|%C@|0\n' 2>/dev/null
    done < <(findmnt -rn -o TARGET,FSTYPE 2>/dev/null | awk '$2 ~ /^(ext[234]|xfs|btrfs|vfat|zfs)$/ {print $1}') \
        | awk -F'|' 'BEGIN{OFS="|"} NF==11 { $8=int($8); $9=int($9); $10=int($10); print }' | gzip > "$d/bodyfile.txt.gz"
    note "timeline/bodyfile.txt.gz: $(du -h "$d/bodyfile.txt.gz" | cut -f1). Analyse with: mactime -b bodyfile.txt -d -z UTC > timeline.csv"
    ok "timeline saved"
}

do_collect() {
    phase_begin collect
    log_case "collect include_secrets=$INCLUDE_SECRETS max_log_mb=$MAX_LOG_MB timeline=$TIMELINE"
    collect_volatile
    collect_logs
    collect_config
    collect_apps
    collect_timeline
}

## INVESTIGATE
## --------------------------------------------

i_packages() {
    section "Package integrity (all packages)"
    local d="$CASE/investigate"
    note "dpkg --verify on all packages ..."
    timeout "$LONG_TIMEOUT" dpkg --verify > "$d/dpkg_verify_all.txt" 2>&1
    parse_dpkg_verify "$d/dpkg_verify_all.txt"
    note "Note: an attacker with root can also change dpkg's own checksum lists; the Wazuh FIM history on the manager is independent."

    section "Files in system directories that no package owns"
    # dpkg's lists use both /bin and /usr/bin (usrmerge): normalise both sides to /usr/...
    # diverted files (e.g. /usr/bin/man on minimized images) are owned too
    { cat /var/lib/dpkg/info/*.list 2>/dev/null; dpkg-divert --list 2>/dev/null | awk '{print $3; print $5}'; } | sed -E 's#^/(bin|sbin|lib|lib32|lib64|libx32)/#/usr/\1/#' | sort -u > "$d/.owned"
    find /usr/bin /usr/sbin /usr/lib/x86_64-linux-gnu/security /usr/lib/aarch64-linux-gnu/security /usr/lib/security /etc/pam.d /usr/lib/systemd/system /lib/modules -xdev -type f 2>/dev/null \
        | sed -E 's#^/(bin|sbin|lib|lib32|lib64|libx32)/#/usr/\1/#' | sort -u > "$d/.present"
    comm -23 "$d/.present" "$d/.owned" > "$d/unowned_system_files.txt"
    rm -f "$d/.owned" "$d/.present"
    local f n=0
    while read -r f; do
        case "$f" in
            /lib/modules/*/modules.*|/usr/lib/modules/*/modules.*) continue ;;   # generated by depmod
            /etc/pam.d/common-*) continue ;;                                    # generated by pam-auth-update
            */security/*|/usr/bin/*|/usr/sbin/*) finding HIGH "File not owned by any package: $(file_meta "$f")"; n=$((n + 1)) ;;
            *) finding MED "File not owned by any package: $f ($(stat -c '%y' "$f"))"; n=$((n + 1)) ;;
        esac
        [[ $n -ge 40 ]] && { finding INFO "More unowned files: see investigate/unowned_system_files.txt"; break; }
    done < "$d/unowned_system_files.txt"
    note "/usr/local is not checked here (Forgejo, PyPy, check-password-expiry.sh live there): see config/etc.tar.gz and the list below."
    find /usr/local -xdev -type f -perm -u+x -printf '%TY-%Tm-%Td %u %m %p\n' 2>/dev/null | sort > "$d/usr_local_executables.txt"

    section "SUID/SGID files"
    find / -xdev \( -path /proc -o -path "$IR_BASE" \) -prune -o -type f \( -perm -4000 -o -perm -2000 \) -print 2>/dev/null | sort > "$d/suid_sgid.txt"
    while read -r f; do
        dpkg -S "$f" >/dev/null 2>&1 || dpkg -S "${f/#\/usr\//\/}" >/dev/null 2>&1 || finding HIGH "SUID/SGID file not owned by any package: $(file_meta "$f")"
    done < "$d/suid_sgid.txt"
    have getcap && { getcap -r / 2>/dev/null | grep -v -E "^$IR_BASE" > "$d/capabilities.txt"; }
}

i_venvs() {
    section "Python virtualenv integrity (pip RECORD hashes)"
    local d="$CASE/investigate/apps" a sp
    mkdir -p "$d"
    local targets=()
    for a in "${APPS[@]}"; do
        while read -r sp; do targets+=("$a:$sp"); done < <(find "$APP_ROOT/$a" -maxdepth 6 -type d \( -name site-packages -o -name dist-packages \) -path '*/lib/*' 2>/dev/null)
    done
    while read -r sp; do targets+=("system:$sp"); done < <(find /usr/local/lib -maxdepth 3 -type d \( -name site-packages -o -name dist-packages \) 2>/dev/null)
    [[ ${#targets[@]} -gt 0 ]] || { note "no virtualenvs found"; return; }
    local t name dir out
    for t in "${targets[@]}"; do
        name="${t%%:*}"; dir="${t#*:}"
        out="$d/venv_${name}_$(echo "$dir" | md5sum | cut -c1-8).txt"
        # system python, isolated (-I): nothing from the checked directory is imported
        python3 -I - "$dir" > "$out" 2>&1 <<'PY'
import base64, csv, hashlib, os, sys
root = sys.argv[1]
recorded, bad, missing = set(), [], 0
for entry in os.listdir(root):
    if not entry.endswith(".dist-info"):
        continue
    rec = os.path.join(root, entry, "RECORD")
    if not os.path.isfile(rec):
        continue
    with open(rec, newline="", encoding="utf-8", errors="replace") as fh:
        for row in csv.reader(fh):
            if not row:
                continue
            rel = row[0]
            path = os.path.normpath(os.path.join(root, rel))
            recorded.add(path)
            if len(row) < 2 or not row[1].startswith("sha256="):
                continue
            want = row[1][7:]
            try:
                with open(path, "rb") as f:
                    got = base64.urlsafe_b64encode(hashlib.sha256(f.read()).digest()).rstrip(b"=").decode()
            except FileNotFoundError:
                missing += 1
                continue
            except OSError:
                continue
            if got != want:
                bad.append(path)
for p in bad:
    # entry-point scripts in bin/ get their paths rewritten by ubuntu_clone_server.sh and venv moves
    print("CHANGED_BIN" if not p.startswith(root + os.sep) else "CHANGED", p)
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d != "__pycache__"]
    for fn in filenames:
        p = os.path.join(dirpath, fn)
        if p in recorded or fn.endswith((".pyc", ".pyo")):
            continue
        if fn.startswith(("_virtualenv", "__editable__")) or fn.endswith("distutils-precedence.pth"):
            print("KNOWN_HOOK", p)
            continue
        if fn.endswith((".py", ".pth", ".so")) or fn in ("sitecustomize.py", "usercustomize.py"):
            print("UNRECORDED", p)
print(f"SUMMARY changed={len(bad)} missing={missing} recorded={len(recorded)}")
PY
        local nchg nunrec
        nchg="$(grep -c '^CHANGED' "$out")"; nunrec="$(grep -c '^UNRECORDED' "$out")"
        local nbin
        nbin="$(grep -c '^CHANGED_BIN' "$out")"
        [[ "$nbin" -gt 0 ]] && finding INFO "$name: $nbin entry-point scripts in bin/ differ from RECORD (normal after ubuntu_clone_server.sh rewrote paths; read them: $(basename "$out"))."
        [[ "$nchg" -gt 0 ]] && finding HIGH "$name: $nchg installed package files differ from their pip RECORD hash in $dir (e.g. $(grep -m1 '^CHANGED' "$out" | cut -d' ' -f2-))."
        grep -E '^UNRECORDED .*(\.pth|sitecustomize\.py|usercustomize\.py)$' "$out" | head -5 | while read -r _ f; do
            finding HIGH "$name: start-up hook not installed by pip: $f (runs at every Python start)."
        done
        [[ "$nunrec" -gt 0 ]] && finding MED "$name: $nunrec .py/.so files in $dir that no package installed (see $(basename "$out"))."
        note "$name $dir: $(grep '^SUMMARY' "$out")"
        # .pth files with code
        find "$dir" -maxdepth 1 -name '*.pth' -print0 2>/dev/null | xargs -0 -r grep -l -E '^(import|exec)' 2>/dev/null | while read -r f; do
            finding INFO "$name: .pth file with code: $f ($(head -c 150 "$f" | tr '\n' ' '))"
        done
    done
}

i_changed_files() {
    section "Files changed in the last $SINCE_DAYS days"
    local d="$CASE/investigate" mins=$((SINCE_DAYS * 1440))
    timeout "$LONG_TIMEOUT" find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path "$IR_BASE" -o -path /var/log -o -path /var/cache \
        -o -path /var/lib/apt/lists -o -path /var/lib/mysql -o -path /var/lib/postgresql -o -path /var/ossec/queue -o -path /var/lib/suricata -o -path /var/lib/fail2ban \
        -o -path /var/lib/systemd/coredump -o -path /var/lib/aide -o -path /snap -o -name __pycache__ \) -prune \
        -o -cmin "-$mins" -printf '%CY-%Cm-%Cd %CH:%CM:%.2CS ctime | %TY-%Tm-%Td %TH:%TM mtime | %u:%g %m %s | %p\n' 2>/dev/null \
        | sort -r > "$d/changed_files_all.txt"
    grep -E '\| (/etc/|/usr/|/boot/|/root/|/var/spool/|/opt/|/srv/|/var/www/|/var/lib/forgejo/repositories/[^|]*/hooks/|/home/)' "$d/changed_files_all.txt" \
        | grep -v -E '/(venv|\.venv|node_modules|\.git)/|/log/|\.log$' > "$d/changed_files_important.txt"
    finding INFO "$(wc -l < "$d/changed_files_all.txt") files changed in the window, $(wc -l < "$d/changed_files_important.txt") in system/config/home directories (investigate/changed_files_important.txt). Read these against your own deployments and apt history."
    local a
    for a in "${APPS[@]}"; do
        mkdir -p "$d/apps/$a"
        grep -F "| $APP_ROOT/$a/" "$d/changed_files_all.txt" | grep -v -E "/(venv|\.venv|node_modules|\.git|log)/" > "$d/apps/$a/changed_files.txt"
        [[ -s "$d/apps/$a/changed_files.txt" ]] && note "$a: $(wc -l < "$d/apps/$a/changed_files.txt") changed files (investigate/apps/$a/changed_files.txt)"
    done
}

i_auth() {
    section "Logins, sudo and account changes"
    local d="$CASE/investigate/auth"
    mkdir -p "$d"
    auth_lines > "$d/.auth_all"
    grep -E 'Accepted |Failed password|Invalid user|session opened for user root' "$d/.auth_all" | tail -n 100000 > "$d/ssh_events.txt"
    grep -E 'sudo(-rs)?(\[[0-9]+\])?: .*COMMAND=' "$d/.auth_all" > "$d/sudo_commands.txt"
    [[ -f /var/log/sudo.log ]] && cat /var/log/sudo.log >> "$d/sudo_commands.txt"
    journalctl --since "-${SINCE_DAYS} days" --no-pager -o short-iso _COMM=sudo 2>/dev/null >> "$d/sudo_commands.txt"
    grep -E 'useradd|userdel|usermod|groupadd|groupmod|gpasswd|passwd\[|chpasswd|new user|new group|add .* to group|password changed|chage' "$d/.auth_all" > "$d/account_changes.txt"
    grep -E ' su(\[[0-9]+\])?: | su: ' "$d/.auth_all" > "$d/su.txt"
    rm -f "$d/.auth_all"
    local n
    n="$(grep -c -E 'useradd|new user' "$d/account_changes.txt")"; [[ "$n" -gt 0 ]] && finding HIGH "$n user creation event(s) in the auth log: investigate/auth/account_changes.txt"
    n="$(grep -c -E 'add .* to group .*(sudo|admin|wheel)|usermod.*-a?G.*(sudo|admin|wheel)' "$d/account_changes.txt")"; [[ "$n" -gt 0 ]] && finding HIGH "$n change(s) to the sudo/admin group."
    n="$(grep -c -E 'password changed|chpasswd' "$d/account_changes.txt")"; [[ "$n" -gt 0 ]] && finding MED "$n password change(s): investigate/auth/account_changes.txt"
    n="$(grep -c -E "$SUSP_RX" "$d/sudo_commands.txt")"; [[ "$n" -gt 0 ]] && finding HIGH "$n sudo command(s) that look like download/reverse-shell one-liners: investigate/auth/sudo_commands.txt"
    finding INFO "sudo commands in window: $(wc -l < "$d/sudo_commands.txt") (investigate/auth/sudo_commands.txt). Compare with what you ran."
    awk '/COMMAND=/ { sub(/.*COMMAND=/, ""); print }' "$d/sudo_commands.txt" | sort | uniq -c | sort -rn | head -40 > "$d/sudo_top_commands.txt"
}

i_weblogs() {
    section "nginx access logs"
    local d="$CASE/investigate/web" f
    mkdir -p "$d"
    local files=()
    for f in /var/log/nginx/*access*.log /var/log/nginx/*access*.log.[0-9]* /var/log/nginx/*access*.log.*.gz; do [[ -f "$f" ]] && files+=("$f"); done
    [[ ${#files[@]} -gt 0 ]] || { note "no nginx access logs"; return; }
    for f in "${files[@]}"; do if [[ "$f" == *.gz ]]; then zcat -- "$f"; else cat -- "$f"; fi; done 2>/dev/null > "$d/.all"
    # combined format: split on double quotes -> $1 = ip - user [time], $2 = request, $3 = status bytes, $6 = user agent
    awk -F'"' '{ split($1,a," "); split($3,b," "); print a[1], b[1], b[2], $2 }' "$d/.all" > "$d/.parsed"
    awk '{c[$1]++} END {for (i in c) print c[i], i}' "$d/.parsed" | sort -rn | head -30 > "$d/top_clients.txt"
    awk '$4 == "POST" {c[$5]++} END {for (i in c) print c[i], i}' "$d/.parsed" | sort -rn | head -50 > "$d/top_post_paths.txt"
    awk '$2 ~ /^5/ {c[$2" "$5]++} END {for (i in c) print c[i], i}' "$d/.parsed" | sort -rn | head -50 > "$d/top_5xx.txt"
    awk '$3 ~ /^[0-9]+$/ && $3 > 5000000 {print}' "$d/.parsed" | sort -k3 -rn | head -50 > "$d/large_responses.txt"
    local rx='(\.\./|%2e%2e|/etc/passwd|/proc/self|union[+ %20]+select|select.+from|sleep\(|benchmark\(|information_schema|<script|%3cscript|\$\{jndi|\{\{.*\}\}|%7b%7b|/bin/(ba)?sh|cmd=|exec=|wget[+ %20]|curl[+ %20]|base64_decode|\.php|\.env|\.git/|wp-admin|/cgi-bin/)'
    grep -i -E "$rx" "$d/.all" > "$d/suspicious_requests.txt"
    # attempts that got a 2xx/3xx answer are more interesting than the 404 noise of scanners
    awk -F'"' '{ split($3,b," "); if (b[1] ~ /^[23]/) print }' "$d/suspicious_requests.txt" > "$d/suspicious_requests_successful.txt"
    awk -F'"' '{ print $6 }' "$d/.all" | grep -i -E 'sqlmap|nikto|nuclei|wpscan|masscan|zgrab|gobuster|dirbuster|feroxbuster|hydra|python-requests|curl/|wget/|go-http-client' \
        | sort | uniq -c | sort -rn | head -30 > "$d/tool_user_agents.txt"
    finding INFO "nginx: $(wc -l < "$d/.all") requests, $(wc -l < "$d/suspicious_requests.txt") match attack patterns (mostly scanner noise), $(wc -l < "$d/suspicious_requests_successful.txt") of those answered 2xx/3xx: investigate/web/"
    [[ -s "$d/suspicious_requests_successful.txt" ]] && finding MED "Attack-pattern requests with a 2xx/3xx answer: check investigate/web/suspicious_requests_successful.txt (path traversal, SQLi, template injection that worked?)."
    [[ -s "$d/large_responses.txt" ]] && finding INFO "Responses over 5 MB: investigate/web/large_responses.txt (data exfiltration?)."
    rm -f "$d/.all" "$d/.parsed"
    # app logs: tracebacks often show the exploit attempt
    local a
    for a in "${APPS[@]}"; do
        [[ -d "$APP_ROOT/$a/log" ]] || continue
        n="$(grep -r -c -h 'Traceback' "$APP_ROOT/$a/log" 2>/dev/null | awk '{s+=$1} END {print s+0}')"
        [[ "$n" -gt 0 ]] && note "$a: $n Python tracebacks in $APP_ROOT/$a/log (copied in logs/logs.tar.gz)"
    done
}

i_suricata() {
    section "Suricata alerts"
    local d="$CASE/investigate/suricata" f
    have jq || { note "jq not installed"; return; }
    [[ -f /var/log/suricata/eve.json ]] || { note "no /var/log/suricata/eve.json"; return; }
    mkdir -p "$d"
    local since; since="$(since_iso)"
    for f in /var/log/suricata/eve.json /var/log/suricata/eve.json.[0-9]* /var/log/suricata/eve.json.*.gz; do
        [[ -f "$f" ]] || continue
        if [[ "$f" == *.gz ]]; then zcat -- "$f"; else cat -- "$f"; fi
    done 2>/dev/null | grep '"event_type":"alert"' \
        | jq -c --arg since "$since" 'select(.timestamp >= $since) | {t: .timestamp, sev: .alert.severity, sig: .alert.signature, sid: .alert.signature_id, src: .src_ip, sport: .src_port, dst: .dest_ip, dport: .dest_port, proto: .proto, cid: .community_id}' \
        2>/dev/null > "$d/alerts.jsonl"
    jq -r '"\(.sev) \(.sig)"' "$d/alerts.jsonl" | sort | uniq -c | sort -rn | head -50 > "$d/top_signatures.txt"
    jq -r '.src' "$d/alerts.jsonl" | sort | uniq -c | sort -rn | head -30 > "$d/top_sources.txt"
    jq -c 'select(.sev <= 2)' "$d/alerts.jsonl" > "$d/severity_1_2.jsonl"
    # alerts where this server is the source of the traffic: outbound C2, scanning, miner pools
    local myips
    myips="$(ip -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); printf "%s|", a[1]}')"; myips="${myips%|}"
    if [[ -n "$myips" ]]; then
        jq -c --arg rx "^(${myips//./\\.})$" 'select((.src // "") | test($rx))' "$d/alerts.jsonl" > "$d/outbound_alerts.jsonl"
        [[ -s "$d/outbound_alerts.jsonl" ]] && finding HIGH "Suricata: $(wc -l < "$d/outbound_alerts.jsonl") alerts with THIS server as the source (outbound C2/scanning?): investigate/suricata/outbound_alerts.jsonl"
    fi
    finding INFO "Suricata: $(wc -l < "$d/alerts.jsonl") alerts since $since, $(wc -l < "$d/severity_1_2.jsonl") of severity 1-2 (investigate/suricata/). Correlate with nginx logs by community_id/IP and time."
}

i_audit() {
    section "auditd"
    have aureport || { note "auditd tools not installed"; return; }
    local d="$CASE/investigate/audit" ts
    mkdir -p "$d"
    ts="$(date -d "-${SINCE_DAYS} days" +%m/%d/%Y)"
    cap "$d/summary.txt" aureport --summary -ts "$ts" 00:00:00 -i
    cap "$d/logins.txt" aureport -l -ts "$ts" 00:00:00 -i
    cap "$d/auth.txt" aureport -au -ts "$ts" 00:00:00 -i
    cap "$d/account_mods.txt" aureport -m -ts "$ts" 00:00:00 -i
    cap "$d/executables.txt" aureport -x --summary -ts "$ts" 00:00:00 -i
    cap "$d/failed.txt" aureport --failed --summary -ts "$ts" 00:00:00 -i
    cap "$d/anomalies.txt" aureport -n -ts "$ts" 00:00:00 -i
    # keys of the Neo23x0 ruleset (keys that do not exist simply return nothing)
    local k
    for k in susp_activity susp_shell recon sshd cron systemd pam actions rootcmd etcpasswd etcgroup passwd_modification user_modification \
             group_modification network_modifications kernel_modules modules code_injection power_abuse privileged T1219_Remote_Access_Tools \
             sbin_susp perm_mod specialfiles shell_profiles mail data_injection register_injection tracing; do
        timeout "$CMD_TIMEOUT" ausearch -k "$k" -ts "$ts" 00:00:00 -i > "$d/key_$k.txt" 2>/dev/null
        [[ -s "$d/key_$k.txt" ]] || rm -f "$d/key_$k.txt"
    done
    # commands run by the web app users
    local unit user uid
    while read -r unit; do
        [[ -n "$unit" ]] || continue
        user="$(unit_user "$unit")"; uid="$(id -u "$user" 2>/dev/null)" || continue
        timeout "$CMD_TIMEOUT" ausearch -ua "$uid" -sc execve -ts "$ts" 00:00:00 -i 2>/dev/null | grep -E '^type=(EXECVE|SYSCALL)' > "$d/execve_${user}.txt"
        [[ -s "$d/execve_${user}.txt" ]] && finding INFO "auditd recorded program starts by $user ($unit): investigate/audit/execve_${user}.txt"
    done < <(all_app_units)
    [[ -s "$d/key_susp_activity.txt" ]] && finding MED "auditd 'susp_activity' events (nc, wget, curl, ...): investigate/audit/key_susp_activity.txt"
    [[ -s "$d/key_susp_shell.txt" ]] && finding MED "auditd 'susp_shell' events: investigate/audit/key_susp_shell.txt"
    note "auditd reports in investigate/audit/"
}

i_mysql() {
    section "MySQL / MariaDB"
    have mysql || { note "mysql client not installed"; return; }
    local d="$CASE/investigate/mysql"
    mkdir -p "$d"
    timeout 20 mysql -N -B -e 'SELECT 1' >/dev/null 2>&1 || { finding INFO "Cannot log in to MySQL as root over the unix socket: database checks skipped (run them by hand, see the howto)."; return; }
    q() { timeout "$CMD_TIMEOUT" mysql -B -e "$1" 2>&1; }
    local mariadb=n
    mysql -N -B -e 'SELECT VERSION()' 2>/dev/null | grep -qi mariadb && mariadb=y
    if [[ "$mariadb" == "y" ]]; then
        q "SELECT user, host, plugin, is_role, password_expired, account_locked FROM mysql.user ORDER BY user, host" > "$d/users.txt"
    else
        q "SELECT user, host, plugin, account_locked, password_last_changed FROM mysql.user ORDER BY user, host" > "$d/users.txt"
    fi
    q "SELECT CONCAT('SHOW GRANTS FOR ', QUOTE(user), '@', QUOTE(host), ';') FROM mysql.user" | tail -n +2 \
        | timeout "$CMD_TIMEOUT" mysql -N -B > "$d/grants.txt" 2>&1
    q "SHOW FULL PROCESSLIST" > "$d/processlist.txt"
    q "SHOW VARIABLES WHERE Variable_name IN ('secure_file_priv','general_log','general_log_file','log_bin','log_bin_basename','local_infile','bind_address','skip_networking','plugin_dir')" > "$d/variables.txt"
    q "SELECT * FROM mysql.func" > "$d/udf.txt"
    q "SELECT TRIGGER_SCHEMA, TRIGGER_NAME, EVENT_OBJECT_TABLE, ACTION_TIMING, EVENT_MANIPULATION, CREATED FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA NOT IN ('mysql','sys','performance_schema')" > "$d/triggers.txt"
    q "SELECT EVENT_SCHEMA, EVENT_NAME, STATUS, CREATED, LAST_ALTERED, EVENT_DEFINITION FROM information_schema.EVENTS" > "$d/events.txt"
    q "SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE, CREATED, LAST_ALTERED, DEFINER FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA NOT IN ('mysql','sys','performance_schema')" > "$d/routines.txt"
    q "SHOW BINARY LOGS" > "$d/binary_logs.txt"
    [[ "$(wc -l < "$d/udf.txt")" -gt 1 ]] && ! grep -q ERROR "$d/udf.txt" && finding HIGH "MySQL has user-defined functions (UDF, a classic way to run OS commands): investigate/mysql/udf.txt"
    [[ "$(wc -l < "$d/triggers.txt")" -gt 1 ]] && finding INFO "MySQL triggers exist: investigate/mysql/triggers.txt (expected only if your apps use them)."
    [[ "$(wc -l < "$d/events.txt")" -gt 1 ]] && finding MED "MySQL scheduled events exist: investigate/mysql/events.txt"
    awk -F'\t' 'NR > 1 && $2 == "%" {print $1"@"$2}' "$d/users.txt" | while read -r u; do finding MED "MySQL account $u accepts connections from any host."; done
    grep -E 'GRANT .*(ALL PRIVILEGES ON \*\.\*|FILE|SUPER|PROCESS|CREATE USER|GRANT OPTION)' "$d/grants.txt" \
        | grep -v -E "TO [\`'\"](root|debian-sys-maint|mysql\.sys|mysql\.session|mysql\.infoschema|mariadb\.sys|mysql)[\`'\"]@" | while read -r g; do
        finding HIGH "MySQL account with server-wide privileges: $(echo "$g" | cut -c1-200)"
    done
    if [[ "$mariadb" == "n" ]]; then
        awk -F'\t' -v s="$(since_iso)" 'NR > 1 && $5 ~ /^[0-9]/ && $5 >= s {print $1"@"$2" "$5}' "$d/users.txt" | while read -r u; do
            finding MED "MySQL password changed in the window: $u"
        done
    fi
    grep -q -E 'secure_file_priv[[:space:]]*$' "$d/variables.txt" && finding MED "MySQL secure_file_priv is empty: LOAD_FILE/INTO OUTFILE can reach any path the mysql user can."
    grep -q -E '^log_bin[[:space:]]+ON' "$d/variables.txt" && finding INFO "MySQL binary logging is on: the binlogs (SHOW BINARY LOGS) record every data change; mysqlbinlog can show what was changed and when."
    note "database account and object listings in investigate/mysql/ (no password hashes)"
}

i_forgejo() {
    section "Forgejo"
    [[ -d /var/lib/forgejo ]] || { note "Forgejo not installed"; return; }
    local d="$CASE/investigate/forgejo" ini=/etc/forgejo/app.ini dbtype dbpath reporoot
    mkdir -p "$d"
    dbtype="$(awk -F'=' '/^\[database\]/{s=1;next} /^\[/{s=0} s && $1 ~ /^[[:space:]]*DB_TYPE/ {gsub(/[[:space:]]/,"",$2); print $2}' "$ini" 2>/dev/null)"
    dbpath="$(awk -F'=' '/^\[database\]/{s=1;next} /^\[/{s=0} s && $1 ~ /^[[:space:]]*PATH/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}' "$ini" 2>/dev/null)"
    reporoot="$(awk -F'=' '/^\[repository\]/{s=1;next} /^\[/{s=0} s && $1 ~ /^[[:space:]]*ROOT[[:space:]]*$/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}' "$ini" 2>/dev/null)"
    [[ -n "$dbpath" ]] || dbpath="/var/lib/forgejo/data/forgejo.db"
    [[ -n "$reporoot" ]] || reporoot="/var/lib/forgejo/repositories"
    if [[ "${dbtype:-sqlite3}" == "sqlite3" && -f "$dbpath" ]]; then
        # read-only, immutable: no write, no journal, nothing changes in the database file
        python3 -I - "$dbpath" "$(date -u -d "-${SINCE_DAYS} days" +%s)" > "$d/db_report.txt" 2>&1 <<'PY'
import sqlite3, sys, time
db, since = sys.argv[1], int(sys.argv[2])
con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True)
def t(v):
    return time.strftime("%Y-%m-%d %H:%M", time.gmtime(v)) if v else "-"
def q(title, sql, cols, flagcol=None):
    print(f"## {title}")
    try:
        rows = con.execute(sql).fetchall()
    except sqlite3.Error as e:
        print("  (not available:", e, ")"); return
    for r in rows:
        r = list(r)
        mark = "  RECENT" if flagcol is not None and r[flagcol] and r[flagcol] >= since else ""
        print("  " + " | ".join(f"{c}={t(v) if c.endswith('_unix') else v}" for c, v in zip(cols, r)) + mark)
q("users", "SELECT id, lower_name, email, is_admin, is_active, prohibit_login, created_unix, updated_unix, last_login_unix FROM user WHERE type = 0 ORDER BY id",
  ["id", "name", "email", "is_admin", "is_active", "prohibit_login", "created_unix", "updated_unix", "last_login_unix"], 6)
q("ssh keys", "SELECT k.id, u.lower_name, k.name, k.fingerprint, k.created_unix, k.updated_unix FROM public_key k LEFT JOIN user u ON u.id = k.owner_id ORDER BY k.created_unix",
  ["id", "owner", "name", "fingerprint", "created_unix", "updated_unix"], 4)
q("deploy keys", "SELECT d.id, d.repo_id, d.name, d.fingerprint, d.mode, d.created_unix FROM deploy_key d ORDER BY d.created_unix",
  ["id", "repo_id", "name", "fingerprint", "mode", "created_unix"], 5)
q("access tokens", "SELECT a.id, u.lower_name, a.name, a.scope, a.created_unix, a.updated_unix FROM access_token a LEFT JOIN user u ON u.id = a.uid ORDER BY a.created_unix",
  ["id", "owner", "name", "scope", "created_unix", "updated_unix"], 4)
q("webhooks", "SELECT id, repo_id, owner_id, url, is_active, created_unix, updated_unix FROM webhook ORDER BY created_unix",
  ["id", "repo_id", "owner_id", "url", "is_active", "created_unix", "updated_unix"], 5)
q("oauth2 applications", "SELECT id, uid, name, created_unix FROM oauth2_application", ["id", "uid", "name", "created_unix"], 3)
q("two-factor", "SELECT uid, created_unix FROM two_factor", ["uid", "created_unix"], 1)
q("actions runners", "SELECT id, name, owner_id, repo_id, created FROM action_runner", ["id", "name", "owner_id", "repo_id", "created"], None)
q("repositories pushed recently", "SELECT id, lower_name, owner_name, updated_unix FROM repository ORDER BY updated_unix DESC LIMIT 30",
  ["id", "name", "owner", "updated_unix"], 3)
PY
        grep -q 'is_admin=1.*RECENT' "$d/db_report.txt" && finding HIGH "Forgejo: an admin account was created in the last $SINCE_DAYS days (investigate/forgejo/db_report.txt)."
        local n
        n="$(sed -n '/^## ssh keys/,/^## /p' "$d/db_report.txt" | grep -c RECENT)"; [[ "$n" -gt 0 ]] && finding MED "Forgejo: $n SSH key(s) added in the window."
        n="$(sed -n '/^## access tokens/,/^## /p' "$d/db_report.txt" | grep -c RECENT)"; [[ "$n" -gt 0 ]] && finding MED "Forgejo: $n access token(s) created in the window."
        n="$(sed -n '/^## webhooks/,/^## /p' "$d/db_report.txt" | grep -c RECENT)"; [[ "$n" -gt 0 ]] && finding MED "Forgejo: $n webhook(s) created in the window (can send code elsewhere)."
        n="$(sed -n '/^## deploy keys/,/^## /p' "$d/db_report.txt" | grep -c RECENT)"; [[ "$n" -gt 0 ]] && finding MED "Forgejo: $n deploy key(s) added in the window."
    else
        finding INFO "Forgejo database is '${dbtype:-?}' or not found at $dbpath: list users/keys/tokens with 'forgejo admin user list' and the web UI (see the howto)."
    fi
    # server-side git hooks: run on every push, as the git user
    if [[ -d "$reporoot" ]]; then
        find "$reporoot" -mindepth 3 -maxdepth 4 -path '*/hooks/*' -type f ! -name '*.sample' -printf '%TY-%Tm-%Td %TH:%TM ctime=%CY-%Cm-%Cd %u %m %p\n' 2>/dev/null | sort > "$d/repo_hooks.txt"
        find "$reporoot" -mindepth 3 -maxdepth 5 -path '*/hooks/*' -type f ! -name '*.sample' -cmin "-$((SINCE_DAYS * 1440))" 2>/dev/null | head -20 | while read -r f; do
            finding MED "Forgejo repository hook changed in the window: $f"
        done
        find "$reporoot" -mindepth 3 -maxdepth 5 -path '*/hooks/*' -type f ! -name '*.sample' -print0 2>/dev/null | xargs -0 -r grep -l -E "$SUSP_RX|(curl|wget|nc|socat)[[:space:]]" 2>/dev/null | head -20 | while read -r f; do
            finding HIGH "Forgejo repository hook with network/shell one-liner: $f"
        done
    fi
    local gh
    gh="$(getent passwd git | cut -d: -f6)"
    if [[ -n "$gh" && -f "$gh/.ssh/authorized_keys" ]]; then
        local nonforgejo
        nonforgejo="$(grep -v -E '^#|^[[:space:]]*$' "$gh/.ssh/authorized_keys" | grep -v -c 'serv key-')"
        [[ "$nonforgejo" -gt 0 ]] && finding HIGH "git user's authorized_keys has $nonforgejo entr(y/ies) not written by Forgejo (no 'serv key-' command): direct shell access as git."
    fi
}

i_persistence() {
    section "Other persistence places"
    local d="$CASE/investigate/persistence" f
    mkdir -p "$d"
    grep -r -H -n -E '(Pre|Post)-Invoke|Post-Invoke-Success|APT::Update::' /etc/apt/apt.conf.d/ 2>/dev/null > "$d/apt_hooks.txt"
    grep -E "$SUSP_RX|/tmp/|/dev/shm" "$d/apt_hooks.txt" | while read -r f; do finding HIGH "Suspicious apt hook: $(echo "$f" | cut -c1-200)"; done
    grep -r -H -n 'RUN' /etc/udev/rules.d/ 2>/dev/null > "$d/udev_run.txt"
    [[ -s "$d/udev_run.txt" ]] && finding MED "udev rules with RUN= in /etc/udev/rules.d: investigate/persistence/udev_run.txt"
    grep -r -h -E '^[[:space:]]*install[[:space:]]' /etc/modprobe.d/ 2>/dev/null | grep -v -E '/bin/(true|false)[[:space:]]*$' > "$d/modprobe_install.txt"
    [[ -s "$d/modprobe_install.txt" ]] && finding MED "modprobe 'install' lines that run a program: investigate/persistence/modprobe_install.txt"
    cat /etc/modules /etc/modules-load.d/*.conf 2>/dev/null | grep -v -E '^#|^$' > "$d/modules_load.txt"
    ls -la /etc/update-motd.d/ > "$d/update_motd.txt" 2>&1
    find /etc/update-motd.d -type f -cmin "-$((SINCE_DAYS * 1440))" 2>/dev/null | while read -r f; do finding MED "MOTD script changed (runs as root at login): $f"; done
    grep -H -E "$SUSP_RX" /etc/update-motd.d/* 2>/dev/null | while read -r f; do finding HIGH "Suspicious MOTD script: $(echo "$f" | cut -c1-200)"; done
    cat /etc/ld.so.conf /etc/ld.so.conf.d/* > "$d/ld_so_conf.txt" 2>&1
    grep -q -E '/tmp|/dev/shm|/home|/var/tmp' "$d/ld_so_conf.txt" && finding HIGH "Library search path includes a writable directory: investigate/persistence/ld_so_conf.txt"
    # git hooks in the app checkouts (run on every git pull/commit by the deploying user)
    local a
    for a in "${APPS[@]}"; do
        [[ -d "$APP_ROOT/$a/.git/hooks" ]] || continue
        find "$APP_ROOT/$a/.git/hooks" -type f ! -name '*.sample' 2>/dev/null | while read -r f; do finding MED "$a: active git hook $f (runs on git pull/checkout)"; done
    done
    # nginx: proxy_pass to anywhere but localhost, lua/perl modules
    have nginx && nginx -T 2>/dev/null | grep -n -E '^\s*(proxy_pass|fastcgi_pass|uwsgi_pass|grpc_pass|mirror|load_module|perl|content_by_lua|access_by_lua)' > "$d/nginx_upstreams.txt"
    grep -v -E '(127\.0\.0\.1|localhost|unix:|\[::1\])' "$d/nginx_upstreams.txt" 2>/dev/null | grep -E 'pass|mirror' | while read -r f; do finding MED "nginx sends requests to a non-local upstream: $f"; done
    note "listings in investigate/persistence/"
}

do_investigate() {
    phase_begin investigate
    mkdir -p "$CASE/investigate"
    i_packages; i_venvs; i_changed_files; i_auth; i_weblogs; i_suricata; i_audit; i_mysql; i_forgejo; i_persistence
    if [[ ! -f "$CASE/triage/ps.txt" ]]; then
        # triage was not run for this case: include the quick checks
        section "Quick checks (triage was not run for this case)"
        mkdir -p "$CASE/triage"
        t_ssh; t_sudo; t_preload; t_processes; t_network; t_cron; t_systemd; t_tmp; t_kernel; t_security_services; t_webapps
    fi
    phase_counts
    section "Investigate result"
    printf '  %d HIGH, %d MED findings. All findings: %s/findings.txt\n' "$HIGH_COUNT" "$MED_COUNT" "$CASE"
    note "Next: build the timeline (first suspicious event = earliest compromise time), check the Wazuh manager for the same period, decide which backup is clean."
    log_case "INVESTIGATE high=$HIGH_COUNT med=$MED_COUNT"
}

## SECRETS (rotation checklist)
## --------------------------------------------

# env_keys FILE -> "NAME  (kind)" per variable; values are read to classify them, never printed
env_keys() {
    python3 -I - "$1" <<'PY'
import re, sys
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    line = re.sub(r"^export\s+", "", line)
    if "=" not in line:
        continue
    k, v = line.split("=", 1)
    k, v = k.strip(), v.strip().strip("'\"")
    u = k.upper()
    if re.search(r"(PASS|SECRET|TOKEN|KEY|PRIVATE|CREDENTIAL|SALT|SIGNING|AUTH|COOKIE|SESSION|JWT|DSN|WEBHOOK)", u):
        kind = "SECRET: rotate"
    elif re.search(r"://[^/\s:@]+:[^/\s@]+@", v):
        kind = "SECRET: URL with credentials, rotate"
    elif re.search(r"(USER|LOGIN|ACCOUNT|EMAIL|ID)$", u):
        kind = "identifier (rotate together with its secret)"
    elif len(v) >= 24 and re.fullmatch(r"[A-Za-z0-9+/=_\-.]+", v) and re.search(r"\d", v) and re.search(r"[A-Za-z]", v):
        kind = "looks random: probably a secret, rotate"
    else:
        kind = "probably not a secret (check)"
    print(f"{k}  ({kind})")
PY
}

do_secrets() {
    phase_begin secrets
    local d="$CASE/secrets" out="$CASE/secrets/rotation_checklist.md"
    mkdir -p "$d"
    section "Secret rotation checklist"
    {
    echo "# Secret rotation checklist - $(hostname -f 2>/dev/null || hostname)"
    echo ""
    echo "Generated $(utc) by ubuntu_incident_response.sh. Names and paths only; no values."
    echo "Rotate on the NEW server (or at the provider) after the rebuild, never on the compromised one."
    echo "Treat every secret that was on this server, or typed into it, as known to the attacker."
    echo ""
    echo "## 1. Web apps ($ENV_DIR)"
    local a slug env found=n
    for a in "${APPS[@]}"; do
        slug="$(slugify "$a")"; env="$ENV_DIR/$slug.env"
        echo ""
        echo "### $a"
        if [[ -f "$env" ]]; then
            found=y
            echo "File: \`$env\`"
            echo ""
            env_keys "$env" | sed 's/^/- [ ] /'
        else
            echo "- [ ] \`$env\` not found: find where this app keeps its secrets"
        fi
        echo "- [ ] App user sessions / remember-me / API tokens stored in the app database (rotating the secret key logs everyone out; revoke stored tokens too)"
        echo "- [ ] App user passwords: force a reset if the database may have been read"
    done
    for env in "$ENV_DIR"/*.env; do
        [[ -f "$env" ]] || continue
        local known=n
        for a in "${APPS[@]}"; do [[ "$env" == "$ENV_DIR/$(slugify "$a").env" ]] && known=y; done
        [[ "$known" == "y" ]] && continue
        echo ""; echo "### $(basename "$env") (no matching app directory)"; env_keys "$env" | sed 's/^/- [ ] /'
    done
    echo ""
    echo "## 2. Database"
    if have mysql && timeout 20 mysql -N -B -e 'SELECT 1' >/dev/null 2>&1; then
        mysql -N -B -e "SELECT CONCAT(user,'@',host) FROM mysql.user WHERE user NOT IN ('mysql.sys','mysql.session','mysql.infoschema','mariadb.sys','') ORDER BY user" 2>/dev/null | sed 's/^/- [ ] MySQL account /'
    elif [[ -d /etc/mysql ]]; then
        echo "- [ ] All MySQL/MariaDB accounts (root, debian-sys-maint, every app user): list them on the old server with SELECT user,host FROM mysql.user"
    fi
    [[ -f /etc/mysql/debian.cnf ]] && echo "- [ ] debian-sys-maint (/etc/mysql/debian.cnf): let the new install generate its own, do not restore the old file"
    [[ -d /etc/postgresql ]] && echo "- [ ] PostgreSQL: postgres superuser and every role with a password"
    echo "- [ ] Database passwords in the app .env files (above) must match the new accounts"
    echo ""
    echo "## 3. Server credentials"
    awk -F: '$2 !~ /^[!*]/ && $2 != "" {print "- [ ] Linux password of " $1 " (typed into sudo on the compromised server: assume captured; never reuse it anywhere)"}' /etc/shadow 2>/dev/null
    echo "- [ ] SSH host keys: the new server generates new ones; do not restore /etc/ssh/ssh_host_* from the backup. Update known_hosts on your workstation."
    echo "- [ ] Your SSH login key: rotate if you ever used agent forwarding (ssh -A) or copied the private key to this server"
    echo ""
    echo "### Private keys found on this server (rotate wherever their public half is authorized)"
    local f
    while IFS= read -r -d '' f; do
        if grep -q -E 'BEGIN (OPENSSH|RSA|EC|DSA|ED25519|ENCRYPTED)? ?PRIVATE KEY' "$f" 2>/dev/null; then
            local fp
            fp="$(ssh-keygen -lf "$f" 2>/dev/null | awk '{print $1, $2, $NF}')"
            echo "- [ ] \`$f\` (owner $(stat -c %U "$f")${fp:+, $fp})"
        fi
    done < <(find /root /home /etc /var/lib/forgejo /opt /srv -xdev \( -name venv -o -name .venv -o -name node_modules -o -name .git -o -path /etc/ssl/certs \) -prune \
             -o -type f -size -64k \( -name 'id_*' ! -name '*.pub' -o -name '*.pem' -o -name '*.key' -o -name '*_key' \) -print0 2>/dev/null)
    local user home
    while IFS=: read -r user home; do
        [[ -f "$home/.ssh/config" ]] && echo "- [ ] SSH targets configured for $user (where these keys work): $(awk 'tolower($1)=="host" {for(i=2;i<=NF;i++) printf "%s ", $i}' "$home/.ssh/config")"
        [[ -f "$home/.ssh/known_hosts" ]] && echo "- [ ] $user's known_hosts has $(grep -c -v '^#' "$home/.ssh/known_hosts") hosts this server connected to: check them for lateral movement"
        for f in .my.cnf .pgpass .netrc .git-credentials .config/rclone/rclone.conf .aws/credentials .docker/config.json .config/gh/hosts.yml .s3cfg .boto .config/borg .ssh/authorized_keys; do
            [[ "$f" == .ssh/authorized_keys ]] && continue
            [[ -e "$home/$f" ]] && echo "- [ ] Credential file \`$home/$f\` ($user): rotate what it holds at the other end"
        done
    done < <(homes)
    echo ""
    echo "## 4. Services on this server"
    [[ -d /etc/letsencrypt/live ]] && for f in /etc/letsencrypt/live/*/; do [[ -d "$f" ]] && echo "- [ ] TLS certificate $(basename "$f"): private key exposed: revoke (certbot revoke --cert-name $(basename "$f") --reason keycompromise) and issue a new one on the new server"; done
    ls /etc/letsencrypt/*.ini >/dev/null 2>&1 && echo "- [ ] DNS API credentials for certbot (/etc/letsencrypt/*.ini): rotate at the DNS provider"
    [[ -f /var/ossec/etc/client.keys ]] && echo "- [ ] Wazuh agent key (/var/ossec/etc/client.keys): remove this agent on the manager (manage_agents -r <id>) and enroll the new server fresh; do not restore client.keys"
    [[ -f /var/ossec/etc/authd.pass ]] && echo "- [ ] Wazuh enrollment password (authd.pass): change it on the manager"
    [[ -f /etc/postfix/sasl_passwd ]] && echo "- [ ] SMTP relay account $(awk '{print $2}' /etc/postfix/sasl_passwd 2>/dev/null | cut -d: -f1 | head -1) (/etc/postfix/sasl_passwd): change the password at the mail provider; check its sent-mail log for spam"
    [[ -f /etc/monit/monitrc ]] && echo "- [ ] Monit admin password and mail server password (/etc/monit/monitrc)"
    [[ -f /etc/forgejo/app.ini ]] && echo "- [ ] Forgejo app.ini secrets: SECRET_KEY, INTERNAL_TOKEN, [oauth2] JWT_SECRET, LFS_JWT_SECRET, [database] PASSWD (regenerate: forgejo generate secret ...)"
    [[ -d /var/lib/forgejo ]] && {
        echo "- [ ] Forgejo user passwords (force reset), personal access tokens, OAuth2 apps, 2FA if the database was readable"
        echo "- [ ] Forgejo SSH keys and deploy keys: review the list (investigate/forgejo/db_report.txt), remove unknown ones"
        echo "- [ ] Forgejo webhooks secrets and Actions runner tokens / secrets"
        echo "- [ ] Code in the repositories: compare with developers' clones (git fsck, unexpected commits or force-pushes)"
    }
    [[ -f /etc/grafana/grafana.ini ]] && echo "- [ ] Grafana secret_key, admin password, SMTP password, data source passwords"
    [[ -d /etc/livekit ]] && echo "- [ ] LiveKit API key/secret (/etc/livekit) and the copies in the apps that call it"
    [[ -f /etc/valkey/valkey.conf ]] && grep -q -E '^[[:space:]]*(requirepass|user )' /etc/valkey/valkey.conf 2>/dev/null && echo "- [ ] Valkey requirepass / ACL users"
    ls /etc/mosquitto/passwd* >/dev/null 2>&1 && echo "- [ ] Mosquitto user passwords"
    [[ -d /etc/webmin ]] && echo "- [ ] Webmin users"
    [[ -f /etc/landscape/client.conf ]] && echo "- [ ] Landscape registration key"
    have pro && timeout 20 pro status 2>/dev/null | grep -q -i 'attached' && echo "- [ ] Ubuntu Pro: detach this machine in the Ubuntu Pro dashboard; attach the new one"
    echo ""
    echo "## 5. Outside this server"
    echo "- [ ] VPS provider account: password, 2FA, API tokens (an attacker on the server may have found a token in a script)"
    echo "- [ ] Domain registrar and DNS provider: check records were not changed; rotate API tokens"
    echo "- [ ] Certificates issued for your domains that you did not request: https://crt.sh/?q=<domain>"
    echo "- [ ] Backup storage credentials (where backups are pushed/pulled) and check the backups themselves for tampering"
    echo "- [ ] Third-party API keys used by the apps (payment, mail, SMS, maps, OAuth client secrets): rotate in each provider's console, check their logs for misuse"
    echo "- [ ] Other servers this one could reach with its keys (section 3): check their auth logs"
    echo "- [ ] Your workstation, if you copied files from the server and opened them"
    echo ""
    echo "## 6. Do NOT restore these from ubuntu_config_*.tar.gz (ubuntu_backup_config.sh)"
    echo "The config backup is fine for reference, but these carry old secrets or attacker changes:"
    echo "- /etc/shadow, /etc/passwd, /etc/group, /etc/sudoers, /etc/sudoers.d (recreate users with ubuntu_provision.sh)"
    echo "- /etc/ssh (host keys), /root/.ssh, /home/*/.ssh/authorized_keys (add your new public key only)"
    echo "- /etc/letsencrypt (issue new certificates), /var/ossec/etc/client.keys (re-enroll)"
    echo "- /etc/postfix/sasl_passwd, /etc/monit/monitrc, /etc/mysql/debian.cnf, /etc/forgejo/app.ini secrets, /etc/grafana/grafana.ini, /etc/livekit"
    echo "- /etc/cron.d, /etc/crontab, /etc/systemd/system overrides: re-create from the repository, or diff against the provisioning templates first"
    echo "- Any backup taken after the earliest compromise time found in the investigation"
    } > "$out"
    note "Checklist: $out"
    note "$(grep -c '^- \[ \]' "$out") items. Copy it into your incident notes; tick items off on the new server."
    log_case "SECRETS checklist written ($(grep -c '^- \[ \]' "$out") items)"
}

## CONTAIN
## --------------------------------------------

contain_precheck() {
    # containment kills evidence: insist on volatile data first, unless explicitly accepted
    if [[ ! -s "$CASE/volatile/ps_forest.txt" ]]; then
        note "${YELLOW}No volatile evidence in $CASE yet (run 'collect' first; it is quick to stop after the volatile part).${NC}"
        confirm "Contain WITHOUT volatile evidence?" || die "Aborted. Run: sudo bash $0 collect"
    fi
}

my_ssh_ip() { [[ -n "${SSH_CLIENT:-}" ]] && printf '%s' "${SSH_CLIENT%% *}"; }

contain_network() {
    have ufw || die "ufw is not installed. Use the provider's firewall (recommended anyway) or add nftables rules by hand."
    have python3 || die "python3 is needed to check the addresses."
    [[ -n "$ADMIN_IPS" ]] || die "--admin-ip is required: the addresses that keep SSH access (e.g. --admin-ip 203.0.113.7). Nothing changed."
    local me; me="$(my_ssh_ip)"
    if [[ -n "$me" ]] && ! ip_in_list "$me" "$ADMIN_IPS"; then
        [[ "$CONSOLE" == "y" ]] || die "Your SSH session comes from $me, which is not in --admin-ip ($ADMIN_IPS): you would lock yourself out. Add it, or use --console if you have the provider console."
    fi
    if [[ -z "$me" && "$CONSOLE" != "y" ]]; then
        die "Not running over SSH (no SSH_CLIENT): if you are on the provider console, add --console."
    fi
    local mgr mgr_ips="" sshport
    mgr="$(wazuh_manager)"
    if [[ -n "$mgr" ]]; then
        mgr_ips="$(getent ahosts "$mgr" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
        [[ -n "$mgr_ips" ]] || die "Cannot resolve the Wazuh manager '$mgr'. Pass its IP with --wazuh-manager, or fix DNS first."
    fi
    sshport="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')"; sshport="${sshport:-22}"
    [[ "$sshport" =~ ^[0-9]+$ ]] || die "Cannot read the SSH port."

    section "Network containment plan"
    note "Allow IN : tcp/$sshport from ${ADMIN_IPS//,/ }"
    [[ -n "$mgr_ips" ]] && note "Allow OUT: tcp/1514,1515 to the Wazuh manager $mgr ($mgr_ips)"
    note "Deny everything else, in and out (web sites go offline; DNS, apt, mail are blocked)."
    [[ "$KEEP_CONNECTIONS" == "y" ]] || note "Then kill established connections that do not involve the addresses above (reverse shells survive a firewall change)."
    note "Previous firewall saved to $CASE/containment/ for 'contain undo-network'."
    confirm "Apply network containment now?" || die "Aborted, nothing changed."

    local bk="$CASE/containment/ufw_before_${RUN_TS}"
    mkdir -p "$bk"
    cp -a /etc/ufw "$bk/etc_ufw" && cp -a /etc/default/ufw "$bk/etc_default_ufw" || die "Could not back up /etc/ufw and /etc/default/ufw; nothing changed."
    ufw status numbered > "$bk/ufw_status_numbered.txt" 2>&1
    iptables-save > "$bk/iptables.txt" 2>/dev/null
    ss -tunapH > "$bk/ss_before.txt" 2>/dev/null
    # undo goes back to the state before the FIRST containment of this case, not to a half-contained one
    if [[ ! -e "$CASE/containment/ufw_original" ]]; then
        ln -sfn "$(basename "$bk")" "$CASE/containment/ufw_original"
        grep -q 'IR-CONTAIN' "$bk/ufw_status_numbered.txt" && note "${YELLOW}[!] The firewall was already contained before this case: 'undo-network' here restores that contained state. Use the case that contained it first.${NC}"
    fi
    log_case "CONTAIN network admin_ips=$ADMIN_IPS manager=$mgr ($mgr_ips) backup=$bk"

    # order matters: own access first, then defaults, then remove the old allow rules; the firewall is never off
    local ip
    for ip in ${ADMIN_IPS//,/ }; do
        ufw prepend allow in proto tcp from "$ip" to any port "$sshport" comment 'IR-CONTAIN' >/dev/null 2>&1 \
            || ufw allow in proto tcp from "$ip" to any port "$sshport" comment 'IR-CONTAIN' >/dev/null \
            || die "Could not add the SSH rule for $ip. Defaults and old rules are unchanged; rules added so far are marked IR-CONTAIN (ufw status)."
    done
    for ip in $mgr_ips; do
        ufw allow out proto tcp to "$ip" port 1514,1515 comment 'IR-CONTAIN' >/dev/null || note "[!] could not add the Wazuh rule for $ip"
    done
    ufw default deny incoming >/dev/null
    ufw default deny outgoing >/dev/null
    ufw default deny routed >/dev/null
    ufw status | head -1 | grep -q 'Status: active' || ufw --force enable >/dev/null
    local nums
    nums="$(ufw status numbered | grep -E '^\[ *[0-9]+\]' | grep -v 'IR-CONTAIN' | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn)"
    for ip in $nums; do ufw --force delete "$ip" >/dev/null; done
    ok "Firewall: only the rules marked IR-CONTAIN remain"
    ufw status verbose | sed 's/^/    /'

    if [[ "$KEEP_CONNECTIONS" != "y" ]]; then
        local filter="( not dst 127.0.0.0/8 and not dst [::1]"
        for ip in ${ADMIN_IPS//,/ } $mgr_ips; do
            # ss wants IPv6 in brackets, prefix inside: [2001:db8::/48]
            if [[ "$ip" == *:* ]]; then filter+=" and not dst [$ip]"; else filter+=" and not dst $ip"; fi
        done
        filter+=" )"
        ss -tnpH state established "$filter" > "$CASE/containment/killed_connections_${RUN_TS}.txt" 2>&1
        if ! ss -tnH state established "$filter" >/dev/null 2>&1; then
            note "[!] Could not build the connection filter '$filter': no connections killed. Check 'ss -tnp state established'."
        elif ss -K -tn state established "$filter" >/dev/null 2>&1; then
            ok "Killed $(grep -c . "$CASE/containment/killed_connections_${RUN_TS}.txt") established connections (list in containment/)"
        else
            note "[!] ss -K failed (kernel without sock_destroy?). Reverse shells may still be connected: check 'ss -tnp state established'."
        fi
    fi
    log_case "CONTAIN network applied"
    note "Test now from a NEW terminal that you can still log in, before closing this one."
}

contain_undo_network() {
    local bk="$CASE/containment/ufw_original"
    [[ -d "$bk/etc_ufw" && -f "$bk/etc_default_ufw" ]] || die "No saved firewall in $CASE/containment/ (contain network was not run with this case)."
    note "Restore /etc/ufw and /etc/default/ufw (default policies) from $(readlink -f "$bk") and reload."
    confirm "Undo network containment (re-opens everything the old rules allowed)?" || die "Aborted, nothing changed."
    cp -a /etc/ufw "$CASE/containment/ufw_contained_${RUN_TS}" 2>/dev/null
    cp -a /etc/default/ufw "$CASE/containment/ufw_contained_${RUN_TS}/etc_default_ufw" 2>/dev/null
    cp -a "$bk/etc_default_ufw" /etc/default/ufw || die "Could not restore /etc/default/ufw."
    rsync -a --delete "$bk/etc_ufw/" /etc/ufw/ 2>/dev/null || { rm -rf /etc/ufw.ir-new && cp -a "$bk/etc_ufw" /etc/ufw.ir-new && rm -rf /etc/ufw && mv /etc/ufw.ir-new /etc/ufw; } || die "Could not restore /etc/ufw."
    ufw reload >/dev/null || die "ufw reload failed: check /etc/ufw."
    # the restored state is the baseline for a later containment
    rm -f -- "$CASE/containment/ufw_original"
    log_case "CONTAIN undo-network from $(readlink -f "$bk")"
    ok "Firewall restored"; ufw status | sed 's/^/    /'
}

contain_webapps() {
    local units
    units="$(all_app_units)"
    [[ -n "$units" ]] || die "No web app units found for $APP_ROOT."
    section "Web app containment"
    note "Units: $(echo "$units" | tr '\n' ' ')"
    if [[ "$STOP_APPS" == "y" ]]; then
        note "Action: STOP (processes and their memory are gone afterwards)."
    else
        note "Action: FREEZE (processes stay in memory, do nothing; nginx answers with timeouts/502). Use --stop to stop instead."
    fi
    contain_precheck
    confirm "Contain these web apps?" || die "Aborted, nothing changed."
    local u
    for u in $units; do
        if [[ "$STOP_APPS" == "y" ]]; then
            systemctl stop "$u" && ok "stopped $u" || note "[!] could not stop $u"
            log_case "CONTAIN webapps stop $u"
        else
            # fail closed: if freezing is not possible, do not silently stop (that destroys memory evidence)
            if systemctl freeze "$u" 2>/dev/null; then
                ok "frozen $u"; log_case "CONTAIN webapps freeze $u"
            else
                note "[!] could not freeze $u (systemd too old or cgroup v1). Nothing done for it; re-run with --stop to stop it."
                log_case "CONTAIN webapps freeze FAILED $u"
            fi
        fi
    done
    echo "$units" > "$CASE/containment/webapp_units.txt"
}

contain_undo_webapps() {
    [[ -f "$CASE/containment/webapp_units.txt" ]] || die "No contained web apps recorded in this case."
    confirm "Thaw/start the web apps again?" || die "Aborted."
    local u
    while read -r u; do
        [[ -n "$u" ]] || continue
        if [[ "$(systemctl show -p FreezerState --value "$u" 2>/dev/null)" == "frozen" ]]; then
            systemctl thaw "$u" && ok "thawed $u"
        else
            systemctl start "$u" && ok "started $u"
        fi
        log_case "CONTAIN undo-webapps $u"
    done < "$CASE/containment/webapp_units.txt"
}

contain_user() {
    local user="$1" home ak
    [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid user name '$user'."
    id "$user" >/dev/null 2>&1 || die "User '$user' does not exist."
    [[ "$(id -u "$user")" != "0" ]] || die "Refusing to lock a UID 0 account here; handle root from the provider console."
    if [[ "$user" == "${SUDO_USER:-}" && "$CONSOLE" != "y" ]]; then
        die "'$user' is you: locking it ends your access. Use --console if you have the provider console."
    fi
    home="$(getent passwd "$user" | cut -d: -f6)"
    section "Account containment: $user"
    note "Lock password, expire account, move SSH keys aside, end sessions and kill all processes of $user."
    local units
    units="$(all_app_units | while read -r u; do [[ "$(unit_user "$u")" == "$user" ]] && echo "$u"; done)"
    [[ -n "$units" ]] && note "${YELLOW}Web apps running as $user will be killed too: $(echo "$units" | tr '\n' ' ')${NC}"
    contain_precheck
    confirm "Contain account $user?" || die "Aborted, nothing changed."
    mkdir -p "$CASE/containment/user_$user"
    for ak in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
        if [[ -f "$ak" ]]; then
            cp -p -- "$ak" "$CASE/containment/user_$user/"
            mv -- "$ak" "$ak.ir-disabled" && ok "moved $ak aside"
        fi
    done
    usermod -L "$user" && chage -E 0 "$user" && ok "password locked, account expired"
    loginctl terminate-user "$user" 2>/dev/null
    pkill -KILL -u "$user" 2>/dev/null
    ok "sessions and processes of $user ended"
    log_case "CONTAIN user $user"
    note "Undo: usermod -U $user; chage -E -1 $user; mv $home/.ssh/authorized_keys.ir-disabled $home/.ssh/authorized_keys"
}

contain_cron() {
    section "Scheduled job containment"
    note "Stop cron and atd (and list timers): stops persistence that re-runs every few minutes."
    note "Also stops your own jobs (backups, blocklist updates, AIDE) until undone with: systemctl start cron atd"
    confirm "Stop cron and atd?" || die "Aborted."
    systemctl stop cron 2>/dev/null && ok "cron stopped"
    systemctl stop atd 2>/dev/null && ok "atd stopped"
    systemctl list-timers --all --no-pager > "$CASE/containment/timers_${RUN_TS}.txt" 2>&1
    note "systemd timers keep running (apt, logrotate, ...); stop suspicious ones with: systemctl stop <name>.timer"
    log_case "CONTAIN cron stopped"
}

contain_status() {
    section "Containment status"
    have ufw && { ufw status verbose | sed 's/^/    /'; ufw status | grep -q IR-CONTAIN && note "Network: CONTAINED (IR-CONTAIN rules)" || note "Network: not contained"; }
    local u
    for u in $(all_app_units); do note "$u: $(systemctl is-active "$u" 2>/dev/null), freezer $(systemctl show -p FreezerState --value "$u" 2>/dev/null)"; done
    note "cron: $(systemctl is-active cron 2>/dev/null)  atd: $(systemctl is-active atd 2>/dev/null)"
    local f
    for f in /home/*/.ssh/authorized_keys.ir-disabled /root/.ssh/authorized_keys.ir-disabled; do [[ -e "$f" ]] && note "keys disabled: $f"; done
    passwd -S -a 2>/dev/null | awk '$2 == "L" {print "    locked: " $1}'
}

do_contain() {
    phase_begin contain
    mkdir -p "$CASE/containment"
    case "$SUBARG" in
        network)       contain_network ;;
        undo-network)  contain_undo_network ;;
        webapps)       contain_webapps ;;
        undo-webapps)  contain_undo_webapps ;;
        user:*)        contain_user "${SUBARG#user:}" ;;
        cron)          contain_cron ;;
        status)        contain_status ;;
        *) die "Unknown contain action '$SUBARG'." ;;
    esac
}

## EXPORT
## --------------------------------------------

do_export() {
    phase_begin export
    section "Export"
    refresh_manifest
    local base name archive
    base="$(dirname "$CASE")"; name="$(basename "$CASE")"
    archive="$base/${name}_$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
    tar -C "$base" -czf "$archive" "$name" || { rm -f -- "$archive"; die "Packing the case failed."; }
    if [[ -n "$ENCRYPT_TO" ]]; then
        have gpg || { rm -f -- "$archive"; die "--encrypt-to given but gpg is not installed. No archive left behind."; }
        local gh
        gh="$(mktemp -d)"
        if ! gpg --homedir "$gh" --batch --quiet --yes --trust-model always --recipient-file "$ENCRYPT_TO" --output "$archive.gpg" --encrypt "$archive"; then
            rm -rf -- "$gh"; rm -f -- "$archive" "$archive.gpg"
            die "GPG encryption failed. No archive left behind."
        fi
        rm -rf -- "$gh"
        shred -u -- "$archive" 2>/dev/null || rm -f -- "$archive"
        archive="$archive.gpg"
    fi
    ( cd "$base" && sha256sum "$(basename "$archive")" ) > "$archive.sha256"
    if [[ -n "${SUDO_USER:-}" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
        chown "$SUDO_USER:" -- "$archive" "$archive.sha256" && chmod 600 -- "$archive" "$archive.sha256"
        # the directory itself stays root-only; give the sudo user a path to fetch it
        local pickup
        pickup="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        if [[ -d "$pickup" ]]; then
            mv -- "$archive" "$archive.sha256" "$pickup/" && archive="$pickup/$(basename "$archive")"
        fi
    fi
    log_case "EXPORT $archive sha256=$(awk '{print $1}' "$archive.sha256")"
    ok "Archive: $archive ($(du -h "$archive" | cut -f1))"
    note "sha256: $(awk '{print $1}' "$archive.sha256")   <- write this into your incident notes now"
    local ip
    ip="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')"
    note "Fetch it from your workstation:"
    note "  scp ${SUDO_USER:-user}@${ip:-server}:$archive* ."
    note "  sha256sum -c $(basename "$archive").sha256"
    [[ -z "$ENCRYPT_TO" ]] && note "Not encrypted: store it encrypted, and delete it from the server after copying (shred -u $archive)."
    [[ "$INCLUDE_SECRETS" == "y" || -d "$CASE/config/SECRETS" ]] && note "${YELLOW}This archive contains secrets (--include-secrets).${NC}"
}

## Main
## --------------------------------------------

main() {
    parse_args "$@"
    [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0 $COMMAND"
    init_case
    discover_apps
    note "Web apps: ${APPS[*]:-none} (in $APP_ROOT)   Window: last $SINCE_DAYS days"
    case "$COMMAND" in
        triage)      do_triage ;;
        collect)     do_collect ;;
        investigate) do_investigate ;;
        secrets)     do_secrets ;;
        contain)     do_contain ;;
        export)      do_export ;;
        all)         do_triage; do_collect; do_investigate; do_secrets; do_export ;;
    esac
    [[ "$COMMAND" == "export" || "$COMMAND" == "all" ]] || refresh_manifest
    log_case "END command=$COMMAND"
    echo ""
    note "Case: $CASE   (findings.txt, case.log, MANIFEST.sha256)"
}

main "$@"
