#!/bin/bash
# update_server_config.sh — safely re-apply important settings on a server that is already provisioned.
#
# Sections:
#   ssh      the hardened sshd drop-in (/etc/ssh/sshd_config.d/01-<user>-hardened.conf) with the settings
#            ubuntu_provision.sh writes today, AllowUsers, and optionally the CIS ciphers/MACs/KEX and banner.
#   updates  automatic updates and upgrades: on/off, the daily update and upgrade hours, the timezone those
#            hours are in, automatic reboot (and its time), needrestart automatic mode.
#
# Usage: sudo ./utils/update_server_config.sh [ssh] [updates] [--dry-run] [--rollback-minutes N]
#   no section       asks for each section
#   --dry-run        show what would change (diffs); change nothing
#   --rollback-minutes N
#                    SSH only: minutes until the new SSH config is put back automatically unless you confirm
#                    that a new login works (default 5, 2-30)
#
# Every section: shows the current values, asks (Enter keeps the current value), shows a diff, asks for
# confirmation, backs up every file it touches to /root/config-backup/update_config_<time>/, tests the new
# config and restores the backup when a test fails.
#
# SSH safety: the change is refused (nothing is written) when it could lock you out:
#   - AllowUsers empty, an unknown user in it, or the admin user / the user running sudo missing from it
#   - the admin user has no valid public key in its authorized_keys, or StrictModes would reject the key files
#   - more than one *-hardened.conf drop-in, or a rollback timer cannot be created
# Servers provisioned by older versions have the hardened settings in /etc/ssh/sshd_config itself, above the
# Include line. sshd uses the first value it reads, so those lines would override the drop-in: the script
# shows them, takes their AllowUsers/UsePAM as defaults and comments them out (moving them to the drop-in).
# After 'sshd -t' passes and sshd is reloaded, a systemd timer restores the previous config after N minutes
# unless you confirm here that a NEW ssh login works. Existing sessions are never closed by a reload.
#
# Keep the SSH settings in sync with ubuntu_provision.sh (steps 11 and 23).
set -uo pipefail

SSHD_DIR=/etc/ssh/sshd_config.d
SSHD_MAIN=/etc/ssh/sshd_config
APT_SETTINGS=/etc/apt/apt.conf.d/51unattended-upgrades-settings
UPDATE_TIMER_OVR=/etc/systemd/system/apt-daily.timer.d/override.conf
UPGRADE_TIMER_OVR=/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf
NEEDRESTART_CONF=/etc/needrestart/conf.d/50-update-server-config.conf
TS=$(date +%F_%H%M%S)
BACKUP_DIR="/root/config-backup/update_config_$TS"
DRY=n; ROLLBACK_MIN=5; SECTIONS=()

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        ssh|updates) SECTIONS+=("$1") ;;
        --dry-run) DRY=y ;;
        --rollback-minutes)
            shift
            [[ "${1:-}" =~ ^[0-9]{1,2}$ ]] && (( $1 >= 2 && $1 <= 30 )) || { echo "--rollback-minutes needs 2-30" >&2; exit 2; }
            ROLLBACK_MIN="$1" ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown argument: $1" >&2; usage 2 ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || { echo "[!] Run as root (sudo)." >&2; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
[[ "$ID" == "ubuntu" && ( "$VERSION_ID" == "24.04" || "$VERSION_ID" == "26.04" ) ]] \
    || { echo "[!] This script is for Ubuntu 24.04 and 26.04." >&2; exit 1; }

exec 9>/run/lock/update_server_config.lock
flock -n 9 || { echo "[!] Another update_server_config.sh is running." >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------------

# ask VAR "prompt" default  — Enter keeps the default
ask() {
    local __v="$1" __p="$2" __d="${3:-}" __a="" __rc=0
    read -rp "  $__p [${__d}]: " __a || { echo; __rc=1; }
    printf -v "$__v" '%s' "${__a:-$__d}"
    return $__rc
}
# ask_yn VAR "prompt" default(y/n) — anything but y/Y/yes is n
ask_yn() {
    local __v="$1" __yn=""   # not __a: ask() has its own local __a, which would shadow it
    ask __yn "$2 (y/n)" "$3"
    [[ "$__yn" =~ ^([Yy]|[Yy][Ee][Ss])$ ]] && printf -v "$__v" y || printf -v "$__v" n
}

# show_diff CURRENT_FILE NEW_FILE — prints a unified diff, returns 1 when nothing changes
show_diff() {
    local cur="$1" new="$2" src="$1"
    [[ -f "$cur" ]] || src=/dev/null
    if diff -q "$src" "$new" >/dev/null 2>&1; then
        echo "  = $cur unchanged"
        return 1
    fi
    echo "  --- $cur"
    diff -u --label "$cur (current)" --label "$cur (new)" "$src" "$new" | sed '1,2d; s/^/    /'
    return 0
}

# Backups: every touched file is copied (or recorded as "did not exist") before it is changed.
MANIFEST="$BACKUP_DIR/manifest"     # lines: <existed y/n> <path>
backup_file() {
    local f="$1"
    install -d -m 700 "$BACKUP_DIR/files"
    grep -qxF "y $f" "$MANIFEST" 2>/dev/null && return 0
    grep -qxF "n $f" "$MANIFEST" 2>/dev/null && return 0
    if [[ -e "$f" ]]; then
        cp -a --parents "$f" "$BACKUP_DIR/files/" || { echo "  [!] Could not back up $f"; return 1; }
        echo "y $f" >> "$MANIFEST"
    else
        echo "n $f" >> "$MANIFEST"
    fi
    chmod 600 "$MANIFEST"
}
# restore_files PATH... — put the backed-up versions back (remove files that did not exist before)
restore_files() {
    local f
    for f in "$@"; do
        if grep -qxF "y $f" "$MANIFEST" 2>/dev/null; then
            cp -a "$BACKUP_DIR/files$f" "$f" && echo "  [<] Restored $f"
        elif grep -qxF "n $f" "$MANIFEST" 2>/dev/null; then
            rm -f "$f" && echo "  [<] Removed $f (it did not exist before)"
        fi
    done
}

confirm_apply() {
    local ok
    if [[ "$DRY" == "y" ]]; then echo "  (dry run - nothing changed)"; return 1; fi
    ask_yn ok "Apply these changes?" n
    [[ "$ok" == "y" ]] || { echo "  Cancelled - nothing changed."; return 1; }
}

# apt_val KEY — effective value of an apt config key ("" when unset)
apt_val() { apt-config dump "$1" 2>/dev/null | awk -v k="$1" '$1 == k { v = $2 } END { gsub(/^"|";$/, "", v); print v }'; }

timer_hour() {   # timer_hour OVERRIDE_FILE — first hour in the OnCalendar line, "" when not set
    [[ -f "$1" ]] && grep -oP '(?<=OnCalendar=\*-\*-\* )\d+' "$1" | head -1
}

valid_hour() { [[ "${1:-}" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; }

# ---------------------------------------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------------------------------------

# Directives this script owns in the drop-in (lower case). Any other directive in the file is kept.
SSH_MANAGED="usepam permitrootlogin kbdinteractiveauthentication passwordauthentication permitemptypasswords
maxstartups logingracetime maxauthtries pubkeyauthentication allowusers clientaliveinterval clientalivecountmax
maxsessions allowtcpforwarding allowagentforwarding permittunnel tcpkeepalive x11forwarding ignorerhosts
authenticationmethods printmotd loglevel banner hostbasedauthentication permituserenvironment ciphers macs
kexalgorithms challengeresponseauthentication protocol"   # last two: obsolete names written by older versions

# Print the managed part of the drop-in. Same values as ubuntu_provision.sh step 11 (+ step 23 when CIS=y).
ssh_managed_block() {   # ssh_managed_block "ALLOW_USERS" CIS(y/n) [USEPAM yes/no, default yes]
    cat <<EOF
UsePAM ${3:-yes}
PermitRootLogin no
KbdInteractiveAuthentication no
PasswordAuthentication no
PermitEmptyPasswords no
MaxStartups 3:50:10
LoginGraceTime 10
MaxAuthTries 3
PubkeyAuthentication yes
AllowUsers $1
ClientAliveInterval 300
ClientAliveCountMax 2
MaxSessions 2
AllowTcpForwarding yes
AllowAgentForwarding no
PermitTunnel no
TCPKeepAlive no
X11Forwarding no
IgnoreRhosts yes
AuthenticationMethods publickey
PrintMotd yes
EOF
    if [[ "$2" == "y" ]]; then
        cat <<'EOF'
LogLevel INFO
Banner /etc/issue.net
HostbasedAuthentication no
PermitUserEnvironment no
Ciphers aes128-ctr,aes192-ctr,aes256-ctr,aes128-gcm@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-256,hmac-sha2-512,hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521
EOF
    fi
}

# Number of valid public keys USER can log in with, or 0. Also enforces what StrictModes checks
# (sshd ignores key files that are writable by others), so a key that sshd would reject does not count.
ssh_usable_keys() {
    local user="$1" home akf f path count=0 n
    home=$(getent passwd "$user" | cut -d: -f6)
    [[ -n "$home" && -d "$home" ]] || { echo 0; return; }
    akf=$("$SSHD" -T -C "user=$user,host=localhost,addr=127.0.0.1" 2>/dev/null | awk '$1 == "authorizedkeysfile" { $1 = ""; print }')
    [[ -n "$akf" ]] || akf=".ssh/authorized_keys .ssh/authorized_keys2"
    for f in $akf; do
        path="${f//%h/$home}"; path="${path//%u/$user}"; path="${path//%%/%}"
        [[ "$path" == /* ]] || path="$home/$path"
        [[ -f "$path" && -s "$path" ]] || continue
        if ! ssh_path_ok "$user" "$path"; then
            echo "  [!] $path: permissions/owner would make sshd ignore it (StrictModes)" >&2
            continue
        fi
        n=$(ssh-keygen -l -f "$path" 2>/dev/null | grep -c .) || n=0
        count=$((count + n))
    done
    echo "$count"
}
# The file and every directory above it must be owned by root or the user and not group/other-writable.
ssh_path_ok() {
    local user="$1" p="$2" uid owner mode
    uid=$(id -u "$user")
    while [[ -n "$p" && "$p" != "/" ]]; do
        owner=$(stat -c %u "$p" 2>/dev/null) || return 1
        mode=$(stat -c %a "$p" 2>/dev/null) || return 1
        [[ "$owner" == "0" || "$owner" == "$uid" ]] || return 1
        (( (8#$mode & 8#022) == 0 )) || return 1
        p=$(dirname "$p")
    done
    return 0
}

# account_pam_problem USER — with UsePAM yes the PAM account phase runs at every login (also with a key):
# an expired account, or a password past its inactivity period, is then refused. Prints the problem.
# Returns 0 (problem) / 1 (fine).
account_pam_problem() {
    local sh lastchg max inact expire today
    sh=$(getent shadow "$1") || { echo "no shadow entry"; return 0; }
    IFS=: read -r _ _ lastchg _ max _ inact expire _ <<<"$sh"
    today=$(( $(date +%s) / 86400 ))
    if [[ -n "$expire" ]] && (( today >= expire )); then echo "account expired (chage -l $1)"; return 0; fi
    if [[ -n "$lastchg" && -n "$max" && -n "$inact" ]] && (( max < 99999 && lastchg > 0 && today > lastchg + max + inact )); then
        echo "password expired more than $inact days ago - PAM locks the account (chage -l $1)"; return 0
    fi
    return 1
}

section_ssh() {
    echo ""
    echo "=== SSH ==="
    SSHD=$(command -v sshd || echo /usr/sbin/sshd)
    if [[ ! -x "$SSHD" ]]; then echo "  OpenSSH server is not installed - skipped."; return 0; fi
    [[ -d /run/sshd ]] || install -d -m 755 /run/sshd   # sshd -t/-T refuse to run without it
    [[ -d "$SSHD_DIR" ]] || { echo "  [!] $SSHD_DIR not found - skipped."; return 1; }
    if ! "$SSHD" -t 2>"$WORK/sshd-t.err"; then
        echo "  [!] The CURRENT SSH config already fails 'sshd -t' - fix that first:"
        sed 's/^/      /' "$WORK/sshd-t.err"
        return 1
    fi

    # The drop-in only works if sshd_config includes the folder
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_MAIN"; then
        echo "  [!] $SSHD_MAIN has no 'Include /etc/ssh/sshd_config.d/*.conf' line, so no drop-in is read."
        echo "      Add it as the first setting in $SSHD_MAIN, check with 'sshd -t', then run this again. Nothing changed."
        return 1
    fi
    # Settings this script manages that sit in sshd_config ABOVE the Include line win over the drop-in
    # (written there by older versions of the provisioning script). Lines below the Include are overridden
    # by the drop-in and stay as they are.
    local legacy="$WORK/legacy-lines"
    awk -v managed="$SSH_MANAGED" '
        BEGIN { n = split(managed, m, /[ \n]+/); for (i = 1; i <= n; i++) M[m[i]] = 1 }
        /^[[:space:]]*Include[[:space:]]/ { exit }
        /^[[:space:]]*(#|$)/ { next }
        tolower($1) in M { print NR ": " $0 }' "$SSHD_MAIN" > "$legacy"
    local migrate=n
    if [[ -s "$legacy" ]]; then
        echo "  $SSHD_MAIN sets these above its Include line, so they override any drop-in:"
        sed 's/^/      /' "$legacy"
        ask_yn migrate "Move them into the drop-in (they are commented out in $SSHD_MAIN; their AllowUsers and UsePAM become the defaults below)?" y
        if [[ "$migrate" != "y" ]]; then
            echo "  The drop-in would not take effect for these settings. Nothing changed."; return 1
        fi
    fi

    local hardened=() target admin admin_default allow allow_default cis cis_default forgejo=n u ok bad usepam usepam_cur
    mapfile -t hardened < <(find "$SSHD_DIR" -maxdepth 1 -name '*-hardened.conf' -type f | sort)
    if [[ ${#hardened[@]} -gt 1 ]]; then
        echo "  [!] More than one hardened drop-in - sshd uses the first value it reads, so the result is unclear:"
        printf '      %s\n' "${hardened[@]}"
        echo "      Merge them into one file, then run this again. Nothing changed."
        return 1
    fi

    # Admin user: the sudo user the provisioner created. Default: from the file name, else whoever runs sudo.
    admin_default=""
    [[ ${#hardened[@]} -eq 1 ]] && admin_default=$(basename "${hardened[0]}" | sed -n 's/^[0-9]*-\(.*\)-hardened\.conf$/\1/p')
    [[ -z "$admin_default" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && admin_default="$SUDO_USER"
    ask admin "Admin (sudo) user who must always be able to log in" "$admin_default" || return 1
    if [[ ! "$admin" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || ! id "$admin" >/dev/null 2>&1; then
        echo "  [!] '$admin' is not an existing user - nothing changed."; return 1
    fi
    if ! id -nG "$admin" | tr ' ' '\n' | grep -qxE 'sudo|admin'; then
        echo "  [!] '$admin' is not in the sudo group - you could log in but not administer the server. Nothing changed."
        return 1
    fi
    target="${hardened[0]:-$SSHD_DIR/01-$admin-hardened.conf}"
    echo "  Drop-in: $target"

    # AllowUsers: keep what sshd uses today (drop-in or old sshd_config lines); a server without any gets the
    # admin (+ forgejo when it exists).
    allow_default=$("$SSHD" -T 2>/dev/null | awk '$1 == "allowusers" { for (i = 2; i <= NF; i++) printf "%s ", $i }' | sed 's/ $//')
    if [[ -z "$allow_default" ]]; then
        allow_default="$admin"
        id forgejo >/dev/null 2>&1 && allow_default+=" forgejo"
    fi
    echo "  Current effective settings (sshd -T):"
    "$SSHD" -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|authenticationmethods|allowusers|x11forwarding|maxauthtries) ' | sed 's/^/      /'
    ask allow "AllowUsers (space separated)" "$allow_default" || return 1
    allow=$(tr -s ' \t' '  ' <<<"$allow" | sed 's/^ //; s/ $//')
    # Fail closed: empty AllowUsers would allow every account
    [[ -n "$allow" ]] || { echo "  [!] AllowUsers cannot be empty (that allows every account). Nothing changed."; return 1; }
    bad=""
    for u in $allow; do
        [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && id "$u" >/dev/null 2>&1 || bad+=" $u"
    done
    [[ -z "$bad" ]] || { echo "  [!] Not an existing user:$bad (patterns like user@host are not supported here). Nothing changed."; return 1; }
    tr ' ' '\n' <<<"$allow" | grep -qxF -- "$admin" || { echo "  [!] AllowUsers must contain the admin user '$admin'. Nothing changed."; return 1; }
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && ! tr ' ' '\n' <<<"$allow" | grep -qxF -- "$SUDO_USER"; then
        echo "  [!] You are running this as '$SUDO_USER', who is not in AllowUsers - that would lock you out. Nothing changed."
        return 1
    fi
    # Password logins are switched off, so the admin needs a key sshd will accept
    local keys
    keys=$(ssh_usable_keys "$admin")
    if [[ "$keys" -lt 1 ]]; then
        echo "  [!] '$admin' has no usable public key in authorized_keys - with password login off that is a lockout. Nothing changed."
        return 1
    fi
    echo "  '$admin' has $keys usable public key(s)."

    # UsePAM: the provisioner uses yes (PAM account/session checks, CIS login rules). Older versions set no.
    usepam_cur=$("$SSHD" -T 2>/dev/null | awk '$1 == "usepam" { print $2; exit }')
    usepam=yes
    if [[ "$usepam_cur" == "no" ]]; then
        echo "  UsePAM is 'no' today; the current setting is 'yes' (PAM account and session checks run at every login)."
        local up
        ask_yn up "Switch UsePAM to yes?" n
        if [[ "$up" == "y" ]]; then
            local prob
            for u in $allow; do
                if prob=$(account_pam_problem "$u"); then
                    if [[ "$u" == "$admin" ]]; then
                        echo "  [!] $u: $prob - with UsePAM yes '$u' could not log in. Fix the account first. Nothing changed."
                        return 1
                    fi
                    echo "  [!] $u: $prob - with UsePAM yes '$u' cannot log in."
                fi
            done
        else
            usepam=no
        fi
    fi

    cis_default=n
    cat "$target" "$SSHD_MAIN" 2>/dev/null | awk '/^[[:space:]]*Include[[:space:]]/ { exit } 1' \
        | grep -qiE '^[[:space:]]*(Ciphers|Banner)[[:space:]]' && cis_default=y   # drop-in, or old lines above Include
    ask_yn cis "Include the CIS settings (ciphers, MACs, KEX, LogLevel, login banner)?" "$cis_default"
    [[ "$cis" == "y" ]] && id forgejo >/dev/null 2>&1 && forgejo=y   # banner text breaks git over ssh

    # ---- build the new drop-in: managed settings + anything else the old file had ----
    local new="$WORK/sshd-new.conf"
    {
        echo "# Managed by ubuntu_provision.sh / utils/update_server_config.sh."
        echo "# Directives not managed by these scripts are kept below the managed block."
        ssh_managed_block "$allow" "$cis" "$usepam"
    } > "$new"
    : > "$WORK/kept-global"; : > "$WORK/kept-match"
    if [[ -f "$target" ]]; then
        # Global directives not managed here are kept; Match blocks are kept, except the provisioner's
        # "Match User forgejo" block, which is written again below when it is needed.
        awk -v managed="$SSH_MANAGED" -v G="$WORK/kept-global" -v MF="$WORK/kept-match" '
            BEGIN { n = split(managed, m, /[ \n]+/); for (i = 1; i <= n; i++) M[m[i]] = 1 }
            /^[[:space:]]*[Mm]atch[[:space:]]/ { inmatch = 1
                skip = ($0 ~ /^[[:space:]]*[Mm]atch[[:space:]]+[Uu]ser[[:space:]]+forgejo[[:space:]]*$/) }
            inmatch { if (!skip && $0 !~ /^[[:space:]]*$/) print > MF; next }
            /^[[:space:]]*(#|$)/ { next }
            { if (!(tolower($1) in M)) print > G }' "$target"
    fi
    if [[ -s "$WORK/kept-global" ]]; then
        { echo ""; echo "# Kept from the previous file"; cat "$WORK/kept-global"; } >> "$new"
        echo "  Kept from the previous file (not managed here):"; sed 's/^/      /' "$WORK/kept-global"
    fi
    # Match blocks must come last: everything after a Match line belongs to it
    [[ "$forgejo" == "y" ]] && printf '\nMatch User forgejo\n    Banner none\n' >> "$new"
    if [[ -s "$WORK/kept-match" ]]; then
        { echo ""; cat "$WORK/kept-match"; } >> "$new"
        echo "  Kept Match blocks:"; sed 's/^/      /' "$WORK/kept-match"
    fi

    # Syntax test of the drop-in on its own (does not touch the live config)
    if ! "$SSHD" -t -f "$new" 2>"$WORK/sshd-t.err"; then
        echo "  [!] The new drop-in fails 'sshd -t':"; sed 's/^/      /' "$WORK/sshd-t.err"
        echo "      Nothing changed."; return 1
    fi

    local main_new="$WORK/sshd_config.new"
    if [[ "$migrate" == "y" ]]; then
        awk -v managed="$SSH_MANAGED" -v tag="# [moved to $(basename "$target") $TS] " '
            BEGIN { n = split(managed, m, /[ \n]+/); for (i = 1; i <= n; i++) M[m[i]] = 1 }
            /^[[:space:]]*Include[[:space:]]/ { done = 1 }
            !done && $0 !~ /^[[:space:]]*(#|$)/ && (tolower($1) in M) { print tag $0; next }
            { print }' "$SSHD_MAIN" > "$main_new"
    fi

    local banner_new="$WORK/issue.net" changed=n
    echo "Authorized access only. All activity may be monitored and reported." > "$banner_new"
    echo ""
    [[ "$migrate" == "y" ]] && { show_diff "$SSHD_MAIN" "$main_new" && changed=y; }
    show_diff "$target" "$new" && changed=y
    if [[ "$cis" == "y" ]]; then show_diff /etc/issue.net "$banner_new" && changed=y; fi
    [[ "$changed" == "y" ]] || { echo "  SSH config already up to date."; return 0; }
    local sysstate
    sysstate=$(systemctl is-system-running 2>/dev/null)
    if [[ "$DRY" != "y" ]] && ! { command -v systemd-run >/dev/null && [[ "$sysstate" == "running" || "$sysstate" == "degraded" ]]; }; then
        echo "  [!] systemd is not running ($sysstate) - no rollback timer possible, so nothing is changed."; return 1
    fi
    confirm_apply || return 0

    # ---- apply ----
    backup_file "$target" || return 1
    [[ "$cis" == "y" ]] && { backup_file /etc/issue.net || return 1; }
    [[ "$migrate" == "y" ]] && { backup_file "$SSHD_MAIN" || return 1; }
    local files=("$target"); [[ "$cis" == "y" ]] && files+=(/etc/issue.net); [[ "$migrate" == "y" ]] && files+=("$SSHD_MAIN")

    # Rollback script, run by the timer if the new login is not confirmed (also when this session dies)
    local rb="$BACKUP_DIR/rollback-ssh.sh" f unit="ssh-config-rollback-$TS"
    {
        echo '#!/bin/bash'
        echo "# Generated by update_server_config.sh on $TS: puts the previous SSH config back."
        for f in "${files[@]}"; do
            if grep -qxF "y $f" "$MANIFEST"; then printf 'cp -a %q %q\n' "$BACKUP_DIR/files$f" "$f"
            else printf 'rm -f %q\n' "$f"; fi
        done
        echo '[[ -d /run/sshd ]] || install -d -m 755 /run/sshd'
        echo 'if sshd -t; then systemctl is-active --quiet ssh.service && systemctl reload ssh.service; fi'
        printf 'logger -t update_server_config %q\n' "SSH config rolled back from $BACKUP_DIR"
    } > "$rb"
    chmod 700 "$rb"

    [[ "$cis" == "y" ]] && install -m 644 -o root -g root "$banner_new" /etc/issue.net
    install -m 600 -o root -g root "$new" "$target"
    [[ "$migrate" == "y" ]] && install -m "$(stat -c %a "$SSHD_MAIN")" -o root -g root "$main_new" "$SSHD_MAIN"

    if ! "$SSHD" -t 2>"$WORK/sshd-t.err"; then
        echo "  [!] 'sshd -t' fails with the new drop-in:"; sed 's/^/      /' "$WORK/sshd-t.err"
        restore_files "${files[@]}"; echo "  sshd was NOT reloaded."; return 1
    fi
    # Effective values for the admin user (another drop-in or sshd_config could still override them)
    local eff
    eff=$("$SSHD" -T -C "user=$admin,host=localhost,addr=127.0.0.1" 2>/dev/null)
    if ! awk '$1 == "allowusers" { for (i = 2; i <= NF; i++) print $i }' <<<"$eff" | grep -qx -- "$admin"; then
        echo "  [!] After the change sshd would not let '$admin' in (AllowUsers is overridden elsewhere)."
        restore_files "${files[@]}"; echo "  sshd was NOT reloaded."; return 1
    fi
    local k v got warn="" eff_allow
    eff_allow=$(awk '$1 == "allowusers" { for (i = 2; i <= NF; i++) print $i }' <<<"$eff" | sort -u | tr '\n' ' ')
    [[ "$eff_allow" == "$(tr ' ' '\n' <<<"$allow" | sort -u | tr '\n' ' ')" ]] \
        || warn+="      allowusers is '${eff_allow% }', not '$allow'"$'\n'
    # Every managed setting must show up in sshd -T as written (sshd uses the first value it reads)
    while read -r k v; do
        k=${k,,}
        [[ -z "$k" || "$k" == \#* || "$k" == "allowusers" ]] && continue
        got=$(awk -v k="$k" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' <<<"$eff")
        [[ "${got,,}" == "${v,,}" ]] || warn+="      $k is '$got', not '$v'"$'\n'
    done < <(ssh_managed_block "$allow" "$cis" "$usepam")
    if [[ -n "$warn" ]]; then
        echo "  [!] sshd does not use these values - an earlier line in $SSHD_MAIN or another file in $SSHD_DIR sets them:"
        printf '%s' "$warn"
        echo "      (not a lockout risk: AllowUsers and the admin's key were checked)"
    fi

    if ! systemd-run --quiet --unit="$unit" --on-active="${ROLLBACK_MIN}m" --timer-property=AccuracySec=1s /bin/bash "$rb"; then
        echo "  [!] Could not create the rollback timer."
        restore_files "${files[@]}"; echo "  sshd was NOT reloaded."; return 1
    fi
    if systemctl is-active --quiet ssh.service; then
        if ! systemctl reload ssh.service; then
            echo "  [!] Reloading ssh failed - rolling back now."
            systemctl stop "$unit.timer" 2>/dev/null; /bin/bash "$rb"; return 1
        fi
        echo "  [V] sshd reloaded. Your current session stays open."
    else
        echo "  [V] ssh.service is socket-activated and idle - the next login uses the new config."
    fi

    echo ""
    echo "  >>> Open a NEW terminal now and log in:  ssh $admin@$(hostname -f 2>/dev/null || hostname)"
    echo "  >>> Keep this session open. Without confirmation the old config is restored in $ROLLBACK_MIN minutes"
    echo "      (also if this session is cut off). Backup: $BACKUP_DIR"
    trap 'echo; echo "  Interrupted - the rollback timer restores the previous SSH config in up to $ROLLBACK_MIN minutes."; exit 130' INT
    local answer=""
    read -r -t $(( ROLLBACK_MIN * 60 - 20 )) -p "  Did the new login work? Type 'yes' to keep the new config: " answer || true
    trap - INT
    if [[ "$answer" == "yes" ]]; then
        systemctl stop "$unit.timer" 2>/dev/null
        if systemctl is-active --quiet "$unit.timer"; then
            echo "  [!] Could not stop the rollback timer $unit.timer - it will restore the old config. Stop it with: systemctl stop $unit.timer"
            return 1
        fi
        echo "  [V] New SSH config kept. Rollback timer cancelled."
        logger -t update_server_config "SSH config updated ($target), backup in $BACKUP_DIR" 2>/dev/null || true
    else
        echo ""
        echo "  Not confirmed - restoring the previous SSH config now."
        systemctl stop "$unit.timer" 2>/dev/null
        /bin/bash "$rb" && echo "  [<] Previous SSH config restored."
        return 1
    fi
}

# ---------------------------------------------------------------------------------------------------------
# Automatic updates
# ---------------------------------------------------------------------------------------------------------
section_updates() {
    echo ""
    echo "=== Automatic updates ==="
    if ! dpkg-query -W -f='${db:Status-Abbrev}' unattended-upgrades 2>/dev/null | grep -q '^ii'; then
        echo "  [!] unattended-upgrades is not installed - install it first (apt-get install unattended-upgrades). Skipped."
        return 1
    fi
    local cur_lists cur_uu cur_reboot cur_rtime cur_uh cur_gh cur_tz cur_nr=""
    cur_lists=$(apt_val APT::Periodic::Update-Package-Lists)
    cur_uu=$(apt_val APT::Periodic::Unattended-Upgrade)
    cur_reboot=$(apt_val Unattended-Upgrade::Automatic-Reboot)
    cur_rtime=$(apt_val Unattended-Upgrade::Automatic-Reboot-Time)
    cur_uh=$(timer_hour "$UPDATE_TIMER_OVR")
    cur_gh=$(timer_hour "$UPGRADE_TIMER_OVR")
    cur_tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)
    if command -v needrestart >/dev/null; then
        cur_nr=$(cat /etc/needrestart/needrestart.conf /etc/needrestart/conf.d/*.conf 2>/dev/null \
                 | sed -n "s/^[[:space:]]*\$nrconf{restart}[[:space:]]*=[[:space:]]*'\(.\)'.*/\1/p" | tail -1)
        cur_nr=${cur_nr:-i}
    fi

    echo "  Current:"
    echo "    Automatic update of package lists : ${cur_lists:-unset} (APT::Periodic::Update-Package-Lists)"
    echo "    Automatic upgrade                 : ${cur_uu:-unset} (APT::Periodic::Unattended-Upgrade)"
    echo "    apt-get update hour               : ${cur_uh:-packaged default}${cur_uh:+:00 and $(( (cur_uh + 12) % 24 )):00}"
    echo "    apt-get upgrade hour              : ${cur_gh:-packaged default}${cur_gh:+:00}"
    echo "    Timezone (the hours are local)    : ${cur_tz:-unknown}"
    echo "    Automatic reboot when required    : ${cur_reboot:-false}${cur_reboot:+ at ${cur_rtime:-now}}"
    [[ -n "$cur_nr" ]] && echo "    needrestart mode                  : $cur_nr (a = restart services automatically)"
    echo ""

    local en en_def uh gh tz rb rtime nr d
    en_def=n; [[ "$cur_lists" == "1" && "$cur_uu" == "1" ]] && en_def=y
    ask_yn en "Install updates automatically (security fixes every day)?" "$en_def"
    [[ "$en" == "n" ]] && echo "  [!] Without automatic upgrades security fixes are only installed when you upgrade by hand."

    if [[ "$en" == "y" ]]; then
        d=${cur_uh:-10}
        while true; do
            ask uh "Hour to run apt-get update (0-23, also runs 12 hours later)" "$d" || return 1
            valid_hour "$uh" && break; echo "  Enter 0-23."
        done
        d=${cur_gh:-$(( (uh + 1) % 24 ))}
        while true; do
            ask gh "Hour to run apt-get upgrade (0-23)" "$d" || return 1
            valid_hour "$gh" && break; echo "  Enter 0-23."
        done
    fi
    while true; do
        ask tz "Timezone" "$cur_tz" || return 1
        [[ -n "$tz" && -f "/usr/share/zoneinfo/$tz" && "$tz" != *..* ]] \
            && timedatectl list-timezones 2>/dev/null | grep -qxF -- "$tz" && break
        echo "  Unknown timezone (see: timedatectl list-timezones)."
    done
    d=n; [[ "$cur_reboot" =~ ^(true|1|yes|on)$ ]] && d=y
    ask_yn rb "Reboot automatically when an upgrade needs it?" "$d"
    rtime=""
    if [[ "$rb" == "y" ]]; then
        while true; do
            ask rtime "Reboot time (HH:MM, local)" "${cur_rtime:-04:00}" || return 1
            [[ "$rtime" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break; echo "  Enter HH:MM, e.g. 04:00."
        done
    fi
    # unattended-upgrades only reboots when /var/run/reboot-required exists, and only update-notifier-common's
    # kernel hook writes it (missing on minimized installs): without it the automatic reboot never happens.
    local need_un=n
    if [[ "$rb" == "y" && ! -x /etc/kernel/postinst.d/update-notifier ]]; then
        echo "  [!] update-notifier-common is not installed, so nothing tells unattended-upgrades that a reboot is needed."
        ask_yn need_un "Install update-notifier-common (otherwise automatic reboot never happens)?" y
        [[ "$need_un" == "y" ]] || echo "  [!] Automatic reboot is set but will not happen after kernel upgrades."
    fi
    nr=""
    if [[ -n "$cur_nr" ]]; then
        d=n; [[ "$cur_nr" == "a" ]] && d=y
        ask_yn nr "Let needrestart restart services automatically after upgrades (no prompts)?" "$d"
    fi

    # ---- build files ----
    local n_apt="$WORK/apt-settings" n_ut="$WORK/update-timer" n_gt="$WORK/upgrade-timer" n_nr="$WORK/needrestart"
    {
        echo "// Managed by utils/update_server_config.sh - re-run it to change these (edits here are overwritten)."
        echo "// Read after 20auto-upgrades and 50unattended-upgrades, so these values win."
        echo "APT::Periodic::Update-Package-Lists \"$([[ $en == y ]] && echo 1 || echo 0)\";"
        echo "APT::Periodic::Unattended-Upgrade \"$([[ $en == y ]] && echo 1 || echo 0)\";"
        echo "Unattended-Upgrade::Automatic-Reboot \"$([[ $rb == y ]] && echo true || echo false)\";"
        [[ "$rb" == "y" ]] && echo "Unattended-Upgrade::Automatic-Reboot-Time \"$rtime\";"
    } > "$n_apt"
    if ! apt-config -c "$n_apt" dump >/dev/null 2>&1; then echo "  [!] Generated apt settings do not parse. Nothing changed."; return 1; fi
    local touch_timers=n
    if [[ "$en" == "y" ]]; then
        touch_timers=y
        # The empty "OnCalendar=" resets the packaged schedule (same format as ubuntu_provision.sh step 15)
        printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* %s,%s:00\nRandomizedDelaySec=60m\n' "$uh" "$(( (uh + 12) % 24 ))" > "$n_ut"
        printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* %s:00\nRandomizedDelaySec=60m\n' "$gh" > "$n_gt"
        for f in "$n_ut" "$n_gt"; do
            systemd-analyze calendar "$(sed -n 's/^OnCalendar=\(..*\)/\1/p' "$f")" >/dev/null 2>&1 \
                || { echo "  [!] Invalid timer schedule generated. Nothing changed."; return 1; }
        done
    fi
    [[ "$nr" == "y" || "$nr" == "n" ]] && printf "# Managed by utils/update_server_config.sh\n\$nrconf{restart} = '%s';\n" "$([[ $nr == y ]] && echo a || echo i)" > "$n_nr"

    echo ""
    local changed=n f
    show_diff "$APT_SETTINGS" "$n_apt" && changed=y
    if [[ "$touch_timers" == "y" ]]; then
        show_diff "$UPDATE_TIMER_OVR" "$n_ut" && changed=y
        show_diff "$UPGRADE_TIMER_OVR" "$n_gt" && changed=y
    fi
    [[ -f "$n_nr" ]] && { show_diff "$NEEDRESTART_CONF" "$n_nr" && changed=y; }
    [[ "$tz" != "$cur_tz" ]] && { echo "  --- timezone: $cur_tz -> $tz"; changed=y; }
    [[ "$need_un" == "y" ]] && { echo "  --- install package: update-notifier-common"; changed=y; }
    [[ "$changed" == "y" ]] || { echo "  Automatic update settings already up to date."; return 0; }
    confirm_apply || return 0

    # ---- apply: apt settings ----
    backup_file "$APT_SETTINGS" || return 1
    install -m 644 -o root -g root "$n_apt" "$APT_SETTINGS"
    if [[ "$(apt_val APT::Periodic::Unattended-Upgrade)" != "$([[ $en == y ]] && echo 1 || echo 0)" ]]; then
        echo "  [!] apt does not show the new value (a later file in /etc/apt/apt.conf.d overrides it):"
        grep -l 'APT::Periodic::Unattended-Upgrade' /etc/apt/apt.conf.d/* 2>/dev/null | sed 's/^/      /'
        restore_files "$APT_SETTINGS"; return 1
    fi
    echo "  [V] $APT_SETTINGS"

    # ---- timers ----
    if [[ "$touch_timers" == "y" ]]; then
        backup_file "$UPDATE_TIMER_OVR" && backup_file "$UPGRADE_TIMER_OVR" || return 1
        install -d -m 755 "$(dirname "$UPDATE_TIMER_OVR")" "$(dirname "$UPGRADE_TIMER_OVR")"
        install -m 644 "$n_ut" "$UPDATE_TIMER_OVR"
        install -m 644 "$n_gt" "$UPGRADE_TIMER_OVR"
        if systemctl daemon-reload && systemctl restart apt-daily.timer apt-daily-upgrade.timer \
           && systemctl is-active --quiet apt-daily.timer && systemctl is-active --quiet apt-daily-upgrade.timer; then
            echo "  [V] Timers: update at $uh:00 and $(( (uh + 12) % 24 )):00, upgrade at $gh:00 (+ up to 60 min random delay)"
        else
            echo "  [!] The timers did not start with the new schedule - restoring the previous one."
            restore_files "$UPDATE_TIMER_OVR" "$UPGRADE_TIMER_OVR"
            systemctl daemon-reload; systemctl restart apt-daily.timer apt-daily-upgrade.timer
            return 1
        fi
    fi

    # ---- needrestart ----
    if [[ -f "$n_nr" ]]; then
        backup_file "$NEEDRESTART_CONF" || return 1
        install -d -m 755 "$(dirname "$NEEDRESTART_CONF")"
        install -m 644 "$n_nr" "$NEEDRESTART_CONF"
        if perl -c "$NEEDRESTART_CONF" >/dev/null 2>&1; then
            echo "  [V] $NEEDRESTART_CONF"
        else
            echo "  [!] needrestart config does not parse - restored."; restore_files "$NEEDRESTART_CONF"; return 1
        fi
    fi

    # ---- reboot-required flag source ----
    if [[ "$need_un" == "y" ]]; then
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -q update-notifier-common >/dev/null 2>&1 \
           && [[ -x /etc/kernel/postinst.d/update-notifier ]]; then
            echo "  [V] update-notifier-common installed (kernel upgrades now set /var/run/reboot-required)"
            echo "      A kernel installed before now is not flagged: check with the health script or reboot-required-check."
        else
            echo "  [!] Installing update-notifier-common failed - automatic reboot will not happen after kernel upgrades."
            return 1
        fi
    fi

    # ---- timezone (last: the other changes do not depend on it) ----
    if [[ "$tz" != "$cur_tz" ]]; then
        if timedatectl set-timezone "$tz" && [[ "$(timedatectl show -p Timezone --value)" == "$tz" ]]; then
            echo "  [V] Timezone $tz (cron jobs, logs and the timers above now use it)"
            systemctl restart apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
        else
            echo "  [!] Could not set the timezone to $tz - it stays $cur_tz."
            return 1
        fi
    fi
    echo ""
    systemctl list-timers apt-daily.timer apt-daily-upgrade.timer --no-pager 2>/dev/null | sed 's/^/  /'
    logger -t update_server_config "Automatic update settings updated, backup in $BACKUP_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------------------------------------
a=""
if [[ ${#SECTIONS[@]} -eq 0 ]]; then
    ask_yn a "Update the SSH config?" n;                  [[ "$a" == "y" ]] && SECTIONS+=(ssh)
    ask_yn a "Update the automatic update settings?" n;   [[ "$a" == "y" ]] && SECTIONS+=(updates)
    [[ ${#SECTIONS[@]} -gt 0 ]] || { echo "Nothing selected."; exit 0; }
fi
[[ "$DRY" == "y" ]] && echo "Dry run: nothing will be changed."

RC=0
for s in "${SECTIONS[@]}"; do
    "section_$s" || RC=1
done
echo ""
if [[ -f "$MANIFEST" ]]; then echo "Backup of the previous files: $BACKUP_DIR"; fi
(( RC == 0 )) && echo "Done." || echo "Finished with problems - see the [!] lines above."
exit $RC
