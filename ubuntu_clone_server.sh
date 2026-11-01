#!/bin/bash
#
# UBUNTU SERVER CLONE SCRIPT
# Clones a gunicorn/nginx web app, its MySQL schema and its cron jobs from another server.
# by Axel Busch + Claude Sonnet
# -----------------------------------------------------------------------------------------
#
# Usage: sudo bash ubuntu_clone_server.sh [--python 3.14] [ubuntu_clone_server.conf]
#   --python VER  Python version used if the virtual environment has to be built on this server
#                 (python3.14 etc. must be installed). Also PYTHON_VERSION=VER in the .conf file.
#                 Default: empty = the system python3.
# Answers are saved to clone_<time>.conf when you confirm, to clone_debug.conf whenever the script
# stops with an error or is killed, and to clone_aborted.conf on Ctrl-C; pass such a file (or ubuntu_clone_server.conf) to skip the questions.
#
# Run on the TARGET server (this machine). The SOURCE server is reached over SSH with a key
# (no password is used: BatchMode). Under sudo the key of the user who ran sudo is offered as the
# default (e.g. ~/.ssh/id_ed25519); otherwise give the key file's path when prompted.
#
# WHAT IT DOES (every part is optional and asked for first; nothing changes until you confirm):
#   - Web app:  rsync of the app directory, converted gunicorn systemd service, converted
#               nginx site, Let's Encrypt certificate for the new domain (certbot --nginx)
#   - MySQL:    dump of the source schema, import into a new schema, creates the target user
#               with privileges on that one schema only
#   - Cron:     lists the source crontab, you confirm each line, paths/domains are replaced
#
# PREREQUISITES on the target: nginx (and MySQL/MariaDB for the schema clone), installed by
# ubuntu_provision.sh. certbot, rsync are installed here if missing.
#
# Fails closed: any missing/invalid answer, unknown SSH host key, failed login, existing target
# that would be overwritten without confirmation, or missing user aborts instead of continuing.

set -Eeuo pipefail

# Python used when the virtual environment is built here (e.g. "3.14"). Empty = system python3.
# Overridden by PYTHON_VERSION in the .conf file, which is overridden by --python.
PYTHON_VERSION=""

TS="$(date +%F_%H%M%S)"
TMP_DIR=""
BACKUP_DIR=""
EXECUTING="n"      # becomes y once the confirmed clone starts changing things
PAIRS=()
SSH_OPTS=()
RSYNC_SSH=""

## Helpers
## --------------------------------------------

# Deliberate abort. Like on_error it keeps the answers (an explicit 'exit' does not fire the ERR trap).
die() {
    echo "  [!] $*" >&2
    set +e
    trap - ERR
    save_debug_config
    exit 1
}

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then rm -rf -- "$TMP_DIR"; fi
}

# Same structure as ubuntu_provision.sh: on_error is the ERR trap, on_ctrl_c the SIGINT trap,
# both save the answers given so far (save_config) and print how to continue.

# Saves the answers to clone_debug.conf (if any were given) and prints the re-run command.
save_debug_config() {
    if [[ -n "${SRC_HOST:-}" ]]; then
        local config_debug_file="clone_debug.conf"
        echo ""
        save_config "$config_debug_file" || true
        echo "  Run 'sudo bash ubuntu_clone_server.sh $config_debug_file' if you want to continue with these settings."
        echo ""
    fi
}

on_error() {
    local exit_code=$?
    local line="$1"
    set +e
    # Unlike ubuntu_provision.sh the EXIT trap is kept: it only removes the temp dir (which may hold a database dump)
    trap - ERR

    if [[ $exit_code -ne 0 ]]; then
        echo ""
        echo "  [!] Error: Script failed at line $line (exit code $exit_code)."
        if [[ "$EXECUTING" == "y" ]]; then
            echo "      Steps before this one have already been applied (see the log and the [V]/[!] lines above)."
        else
            echo "      Nothing has been cloned yet."
        fi
        [[ -n "$BACKUP_DIR" ]] && echo "  Backups of replaced files: $BACKUP_DIR"
        save_debug_config
    fi
    cleanup
    exit $exit_code
}

# $1 = exit code (default 0, as in ubuntu_provision.sh), $2 = message
on_ctrl_c() {
    local code="${1:-0}" msg="${2:-Aborted by user.}"
    set +e
    trap - ERR
    echo ""

    if [[ "${SRC_HOST:-}" ]]; then
        local config_debug_file="clone_aborted.conf"
        echo "  [!] $msg"
        save_config "$config_debug_file"
        echo "  Configuration saved to: $(pwd)/$config_debug_file"
        echo "  To resume with these settings:"
        echo "    sudo bash ubuntu_clone_server.sh $config_debug_file"
        echo ""
    else
        echo "  [!] $msg (no configuration saved — script was interrupted before any settings were entered)."
        echo ""
    fi
    cleanup
    exit "$code"
}

# ask VAR "prompt" [default] [validator]   -- a non-empty preset VAR (from the .conf) is used as is
ask() {
    local var="$1" prompt="$2" def="${3:-}" validator="${4:-}" v
    while true; do
        if [[ -z "${!var:-}" ]]; then
            if [[ -n "$def" ]]; then
                read -rp "$prompt [$def]: " v
                v="${v:-$def}"
            else
                read -rp "$prompt: " v
            fi
            printf -v "$var" '%s' "$v"
        else
            echo "$prompt: ${!var}"
        fi
        if [[ -n "${!var}" ]] && { [[ -z "$validator" ]] || "$validator" "${!var}"; }; then
            return 0
        fi
        echo "  Invalid or empty value, please try again."
        printf -v "$var" '%s' ""
    done
}

# ask_optional VAR "prompt"   -- empty answer is allowed
ask_optional() {
    local var="$1" prompt="$2" validator="${3:-}" v
    while true; do
        if [[ -z "${!var+x}" ]]; then
            read -rp "$prompt: " v
            printf -v "$var" '%s' "$v"
        else
            echo "$prompt: ${!var}"
        fi
        if [[ -z "${!var}" ]] || [[ -z "$validator" ]] || "$validator" "${!var}"; then return 0; fi
        echo "  Invalid value, please try again."
        unset "$var"
    done
}

ask_secret() {
    local var="$1" prompt="$2" v
    while true; do
        read -rsp "$prompt: " v; echo ""
        if [[ -n "$v" && "$v" != *$'\n'* ]]; then
            printf -v "$var" '%s' "$v"
            return 0
        fi
        echo "  Value cannot be empty."
    done
}

# yn VAR "prompt" [default y|n]
yn() {
    local var="$1" prompt="$2" def="${3:-n}" v
    while true; do
        if [[ -z "${!var:-}" ]]; then
            read -rp "$prompt (y/n) [$def]: " v
            v="${v:-$def}"
        else
            v="${!var}"
            echo "$prompt (y/n): $v"
        fi
        case "${v,,}" in
            y|yes) printf -v "$var" '%s' "y"; return 0 ;;
            n|no)  printf -v "$var" '%s' "n"; return 0 ;;
        esac
        echo "  Please answer y or n."
        printf -v "$var" '%s' ""
    done
}

## Validators (print the reason on failure)
## --------------------------------------------

valid_host() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || { echo "  Use a hostname or IP address (must not start with '-')."; return 1; }
}
valid_user() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9._-]{0,31}$ ]] || { echo "  Not a valid user name."; return 1; }
}
valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( $1 >= 1 && $1 <= 65535 )) || { echo "  Port must be 1-65535."; return 1; }
}
valid_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{1,62}$ ]] \
        || { echo "  Not a valid domain name."; return 1; }
}
# Absolute path, safe characters only (these values end up in remote shell commands and sed/systemd text)
valid_file_path() {
    local p="$1"
    if [[ ! "$p" =~ ^/[A-Za-z0-9._/-]+$ || "$p" == *..* || "$p" == *//* || "$p" == */ ]]; then
        echo "  Use an absolute path with letters, digits, '.', '_', '-' and '/' only (no spaces, no trailing '/')."
        return 1
    fi
}
# Application directory: additionally deep enough and not a system directory
valid_path() {
    local p="$1" first
    valid_file_path "$p" || return 1
    if [[ ! "$p" =~ ^/[^/]+/[^/]+ ]]; then
        echo "  Path must be at least two levels deep (e.g. /home/user/site)."
        return 1
    fi
    first="${p#/}"; first="${first%%/*}"
    case "$first" in
        etc|usr|bin|sbin|lib|lib32|lib64|boot|proc|sys|dev|run|root|snap)
            echo "  Refusing a path under /$first."
            return 1 ;;
    esac
}
valid_service_path() { valid_file_path "$1" && [[ "$1" == *.service ]] || { echo "  Service file must end in .service."; return 1; }; }
valid_python_version() { [[ "$1" =~ ^3\.[0-9]{1,2}$ ]] || { echo "  Python version must look like 3.14."; return 1; }; }
valid_workers() { [[ "$1" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "  Enter a number between 1 and 999."; return 1; }; }
valid_db_schema() { [[ "$1" =~ ^[A-Za-z0-9_]{1,64}$ ]] || { echo "  Schema: letters, digits, '_' only (max 64)."; return 1; }; }
valid_db_user() { [[ "$1" =~ ^[A-Za-z0-9_]{1,32}$ ]] || { echo "  User: letters, digits, '_' only (max 32)."; return 1; }; }
valid_email() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo "  Not a valid email address."; return 1; }; }
valid_keyfile() { [[ -f "$1" && -r "$1" ]] || { echo "  File not found or not readable."; return 1; }; }

slugify() { local s="${1,,}"; s="${s//./_}"; s="${s//-/_}"; printf '%s' "$s"; }

## Text conversion (single pass, literal, longest match first)
## --------------------------------------------

# Fills PAIRS with source->target replacements. Needs SRC_PATH TGT_PATH SRC_DOMAIN TGT_DOMAIN SRC_SLUG TGT_SLUG
build_pairs() {
    PAIRS=()
    local sl tl
    sl="$(slugify "${SRC_DOMAIN%%.*}")"; tl="$(slugify "${TGT_DOMAIN%%.*}")"
    add_pair() { [[ -n "$1" && -n "$2" && "$1" != "$2" ]] && PAIRS+=("$1" "$2") || true; }
    add_pair "$SRC_PATH" "$TGT_PATH"
    add_pair "$SRC_DOMAIN" "$TGT_DOMAIN"
    add_pair "$SRC_SLUG" "$TGT_SLUG"
    add_pair "${sl}_gunicorn_app" "${tl}_gunicorn_app"
}

convert_text() {
    python3 -I -c '
import os, re, sys
a = [os.fsencode(x) for x in sys.argv[1:]]
pairs = dict(zip(a[0::2], a[1::2]))
data = sys.stdin.buffer.read()
if pairs:
    rx = re.compile(b"|".join(re.escape(k) for k in sorted(pairs, key=len, reverse=True)))
    data = rx.sub(lambda m: pairs[m.group(0)], data)
sys.stdout.buffer.write(data)
' "${PAIRS[@]}"
}

set_workers() { sed -E "s/(--workers[[:space:]]+)[0-9]+/\1$1/g"; }

# After rsync: replace the source path, domain and name (dot and underscore forms) inside the copied files.
# Usage: replace_in_tree ROOT   (uses PAIRS, a flat list: from to from to ...)
# Text files only (no NUL byte in the first 8 KB), no symlinks, not inside venv/.git/node_modules/__pycache__/log,
# files over 50 MB are left alone. Files are rewritten in place, so owner and mode stay.
replace_in_tree() {
    python3 -I - "$1" "${PAIRS[@]}" <<'PY'
import os, re, sys
root = sys.argv[1]
a = [os.fsencode(x) for x in sys.argv[2:]]
pairs = dict(zip(a[0::2], a[1::2]))
if not pairs:
    print("  Nothing to replace."); sys.exit(0)
rx = re.compile(b"|".join(re.escape(k) for k in sorted(pairs, key=len, reverse=True)))
skip = {"venv", ".git", "node_modules", "__pycache__", "log"}
changed = scanned = skipped = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in skip and not os.path.islink(os.path.join(dirpath, d))]
    for n in filenames:
        p = os.path.join(dirpath, n)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        try:
            if os.path.getsize(p) > 50 * 1024 * 1024:
                skipped += 1; continue
            with open(p, "rb") as f:
                data = f.read()
            scanned += 1
            if b"\0" in data[:8192]:
                continue
            new, cnt = rx.subn(lambda m: pairs[m.group(0)], data)
            if cnt:
                with open(p, "r+b") as f:
                    f.seek(0); f.write(new); f.truncate()
                changed += 1
                print(f"    {os.path.relpath(p, root)}: {cnt} replacement(s)")
        except OSError as e:
            print(f"    [!] {p}: {e}"); skipped += 1
print(f"  Replaced names in {changed} of {scanned} file(s) ({skipped} skipped).")
PY
}

# After rsync: rewrite absolute source paths inside virtualenvs and repoint absolute symlinks
fix_tree_paths() {
    python3 -I - "$1" "$2" "$3" <<'PY'
import os, sys
root, src, dst = sys.argv[1:4]
srcb, dstb = src.encode(), dst.encode()
venvs = []
for dirpath, dirnames, filenames in os.walk(root):
    if "pyvenv.cfg" in filenames:
        venvs.append(dirpath)
edited = relinked = 0
for dirpath, dirnames, filenames in os.walk(root):
    for n in dirnames + filenames:
        p = os.path.join(dirpath, n)
        if os.path.islink(p):
            t = os.readlink(p)
            if t == src or t.startswith(src + "/"):
                os.unlink(p)
                os.symlink(dst + t[len(src):], p)
                relinked += 1
    for n in filenames:
        p = os.path.join(dirpath, n)
        if os.path.islink(p):
            continue
        inv = None
        for v in venvs:
            if p.startswith(v + os.sep):
                inv = v
                break
        if inv is None:
            continue
        ok = (os.path.dirname(p) == os.path.join(inv, "bin")) or n == "pyvenv.cfg" \
            or n.endswith((".pth", ".egg-link")) or n == "direct_url.json"
        if not ok:
            continue
        with open(p, "rb") as f:
            data = f.read()
        if b"\0" in data[:8192] or srcb not in data:
            continue
        with open(p, "wb") as f:
            f.write(data.replace(srcb, dstb))
        edited += 1
print(f"  Rewrote paths in {edited} virtualenv file(s), repointed {relinked} symlink(s).")
PY
}

## SSH helpers
## --------------------------------------------

build_ssh_opts() {
    SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes
              -o ServerAliveInterval=30 -p "$SRC_PORT")
    if [[ -n "${SRC_KEY:-}" ]]; then SSH_OPTS+=(-i "$SRC_KEY" -o IdentitiesOnly=yes); fi
    RSYNC_SSH="ssh"
    local o
    for o in "${SSH_OPTS[@]}"; do RSYNC_SSH+=" $(printf '%q' "$o")"; done
}

rssh() { ssh -n "${SSH_OPTS[@]}" -- "$SRC_USER@$SRC_HOST" "$@"; }

ensure_host_key() {
    local root_home kh target keys
    root_home="$(getent passwd 0 | cut -d: -f6)"
    kh="$root_home/.ssh/known_hosts"
    target="$SRC_HOST"
    if [[ "$SRC_PORT" != "22" ]]; then target="[$SRC_HOST]:$SRC_PORT"; fi
    if ssh-keygen -F "$target" -f "$kh" >/dev/null 2>&1; then return 0; fi

    echo "  The host key of $target is not known to root yet."
    keys="$(ssh-keyscan -T 10 -p "$SRC_PORT" "$SRC_HOST" 2>/dev/null || true)"
    [[ -n "$keys" ]] || die "Could not fetch the host key of $SRC_HOST:$SRC_PORT (host down or SSH port wrong?)"
    echo "  Fingerprints offered by the server:"
    printf '%s\n' "$keys" | ssh-keygen -lf - | sed 's/^/    /'
    echo "  Compare them on the source server with: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
    local ok=""
    yn ok "  Do the fingerprints match? Trust this host" n
    [[ "$ok" == "y" ]] || die "Host key not trusted. Aborting."
    install -d -m 700 "$root_home/.ssh"
    printf '%s\n' "$keys" >> "$kh"
    chmod 600 "$kh"
}

## MySQL helpers
## --------------------------------------------

cnf_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
sql_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\'/\\\'}"; printf '%s' "$s"; }

# Run a command on the source with the DB credentials supplied through a temporary option file
# (sent over stdin, deleted on exit) so the password never appears in a process list.
# $1 = shell snippet, refer to the option file as "$CNF".
src_mysql() {
    printf '[client]\nuser="%s"\npassword="%s"\n' "$(cnf_escape "$SRC_DB_USER")" "$(cnf_escape "$SRC_DB_PASS")" |
        ssh "${SSH_OPTS[@]}" -- "$SRC_USER@$SRC_HOST" \
            "umask 077; CNF=\$(mktemp) || exit 1; trap 'rm -f \"\$CNF\"' EXIT; cat > \"\$CNF\"; $1"
}

tgt_user_cnf() {
    local f="$TMP_DIR/tgt-user.cnf"
    ( umask 077; printf '[client]\nuser="%s"\npassword="%s"\n' "$(cnf_escape "$TGT_DB_USER")" "$(cnf_escape "$TGT_DB_PASS")" > "$f" )
    printf '%s' "$f"
}

# Local root login. ubuntu_provision.sh gives root@localhost a password, so TGT_ROOT_CNF (a mode-600 option file
# in the temp dir, written by ensure_local_db) is used when the password is needed; the password never appears
# on a command line. Without it, plain 'mysql' is used (root over the unix socket).
TGT_ROOT_CNF=""
mysql_root() {
    if [[ -n "$TGT_ROOT_CNF" ]]; then
        mysql --defaults-extra-file="$TGT_ROOT_CNF" -u root "$@"
    else
        mysql "$@"
    fi
}

## Backup of anything we are about to replace
## --------------------------------------------

backup_file() {
    local f="$1"
    [[ -e "$f" || -L "$f" ]] || return 0
    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="/root/clone_backup_$TS"
        install -d -m 700 "$BACKUP_DIR"
    fi
    cp -a -- "$f" "$BACKUP_DIR/$(echo "$f" | tr '/' '_')"
}

## Gather phase: all questions and read-only checks, nothing is changed here
## --------------------------------------------

# ensure_service UNIT "label" ANSWER_VAR -- if the unit is not running, ask whether to enable and start it
# (declining aborts: the clone cannot work without it)
ensure_service() {
    local unit="$1" label="$2" var="$3"
    if systemctl is-active --quiet "$unit"; then return 0; fi
    echo "  [!] $label ($unit) is installed but not running."
    yn "$var" "  Enable it at boot and start it now" "y"
    [[ "${!var}" == "y" ]] || die "$label must be running for this clone. Start it (systemctl enable --now $unit) and re-run."
    systemctl enable --now "$unit" || die "Could not start $unit. Check: journalctl -u $unit -n 30 --no-pager"
    systemctl is-active --quiet "$unit" || die "$unit did not stay running. Check: journalctl -u $unit -n 30 --no-pager"
    echo "  $unit enabled and started."
}

# Name of the local MySQL-compatible server unit (mysql or mariadb), empty if none is installed
detect_db_unit() {
    local u
    for u in mysql mariadb; do
        if systemctl list-unit-files "$u.service" 2>/dev/null | grep -q "^$u.service"; then printf '%s' "$u"; return 0; fi
    done
}

# The local MySQL/MariaDB must be running and we must be able to log in as root: first without a password
# (unix socket), otherwise with the root password, which is asked for (never saved) and checked.
ensure_local_db() {
    command -v mysql >/dev/null || die "mysql client not found on this server (run ubuntu_provision.sh first)."
    local unit i rc out attempt
    unit="$(detect_db_unit)"
    [[ -n "$unit" ]] || die "No MySQL/MariaDB server is installed on this server (run ubuntu_provision.sh first)."
    ensure_service "$unit" "MySQL/MariaDB" ENABLE_DB_SERVICE

    echo "  Checking the local database login ..."
    out=""
    for i in $(seq 1 30); do
        rc=0; out="$(TGT_ROOT_CNF="" mysql_root -N -B -e 'SELECT 1' 2>&1)" || rc=$?
        if [[ $rc -eq 0 ]]; then TGT_ROOT_CNF=""; return 0; fi
        # ERROR 1045/1698 = the server is up but root needs a password; anything else = not ready yet
        if grep -qE 'ERROR (1045|1698)' <<<"$out"; then break; fi
        sleep 1
    done
    grep -qE 'ERROR (1045|1698)' <<<"$out" || die "$unit does not accept connections. Check: journalctl -u $unit -n 30 --no-pager"

    echo "  MySQL root needs a password (as set by ubuntu_provision.sh). It is only used for this run and never saved."
    for attempt in 1 2 3; do
        ask_secret TGT_MYSQL_ROOT_PASS "MySQL root password on this server"
        TGT_ROOT_CNF="$TMP_DIR/root.cnf"
        ( umask 077; printf '[client]\nuser="root"\npassword="%s"\n' "$(cnf_escape "$TGT_MYSQL_ROOT_PASS")" > "$TGT_ROOT_CNF" )
        if mysql_root -N -B -e 'SELECT 1' >/dev/null 2>&1; then
            echo "  Root login OK."
            return 0
        fi
        TGT_ROOT_CNF=""
        echo "  Login failed ($attempt of 3)."
    done
    die "Could not log in to the local MySQL as root. (Root password forgotten? It can be reset with the usual skip-grant-tables procedure.)"
}

# Under sudo the script runs as root, but the SSH key normally belongs to the user who ran sudo.
# Offer that user's key as the default instead of silently looking in /root/.ssh.
find_invoker_key() {
    local u="${SUDO_USER:-}" home k
    [[ -n "$u" && "$u" != "root" ]] || return 0
    home="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$home" ]] || return 0
    for k in id_ed25519 id_ecdsa id_rsa; do
        if [[ -f "$home/.ssh/$k" ]]; then printf '%s' "$home/.ssh/$k"; return 0; fi
    done
}

gather_ssh() {
    echo ""
    echo "--- Source server ---"
    ask SRC_HOST "Source server IP or hostname" "" valid_host
    ask SRC_PORT "Source SSH port" "22" valid_port
    ask SRC_USER "Source SSH username" "" valid_user

    if [[ -z "${SRC_KEY+x}" ]]; then
        local guess v
        guess="$(find_invoker_key)"
        echo "  This script runs as root (sudo), so root's keys in /root/.ssh would be used, not yours."
        if [[ -n "$guess" ]]; then
            read -rp "SSH private key file [$guess] (Enter = use it, 'none' = root's default keys): " v
            v="${v:-$guess}"
        else
            read -rp "SSH private key file (Enter = root's default keys): " v
        fi
        [[ "${v,,}" == "none" ]] && v=""
        SRC_KEY="$v"
        if [[ -n "$SRC_KEY" ]] && ! valid_keyfile "$SRC_KEY"; then die "Key file '$SRC_KEY' not usable."; fi
    else
        echo "SSH private key file: ${SRC_KEY:-(default keys of root)}"
        if [[ -n "$SRC_KEY" ]] && ! valid_keyfile "$SRC_KEY"; then die "Key file '$SRC_KEY' not usable."; fi
    fi
    if [[ -n "$SRC_KEY" ]] && ! ssh-keygen -y -P "" -f "$SRC_KEY" >/dev/null 2>&1; then
        echo "  [!] The key is passphrase-protected (or unreadable). Passwords/passphrases are never prompted here,"
        echo "      so it only works if an ssh-agent holds it and sudo passes the agent through, e.g.:"
        echo "        sudo --preserve-env=SSH_AUTH_SOCK ./ubuntu_clone_server.sh"
        echo "      (the sudoers 'env_keep' may block this), or use a dedicated key without a passphrase."
    fi

    build_ssh_opts
    ensure_host_key
    echo "  Testing key-based login ..."
    rssh true || die "Login to $SRC_USER@$SRC_HOST failed using ${SRC_KEY:-the default keys of root}. Check that this key's public half is in ~/.ssh/authorized_keys of $SRC_USER on the source. Passwords are not used."
    echo "  Login OK."
}

dir_selected() {   # is top-level directory $1 in the copy list?
    local d
    for d in $COPY_DIRS; do [[ "$d" == "$1" ]] && return 0; done
    return 1
}

# Ask, for every top-level subdirectory of the source path, whether it should be copied.
# Sets DIR_NAMES, DIR_MODES, COPY_DIRS (space separated) and CREATE_EMPTY_DIRS.
gather_dirs() {
    echo ""
    echo "  Subdirectories of $SRC_PATH - choose which to copy."
    echo "  (Files directly in $SRC_PATH are always copied; the contents of log/ never are.)"
    local listing name mode i size_raw names="" line
    DIR_NAMES=(); DIR_MODES=()
    listing="$(rssh "find '$SRC_PATH' -mindepth 1 -maxdepth 1 -type d -printf '%f\t%m\n' | sort")" \
        || die "Cannot list $SRC_PATH on the source server."
    while IFS=$'\t' read -r name mode; do
        [[ -n "$name" ]] || continue
        if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ || ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
            echo "  [!] Skipping '$name': unusual characters, it cannot be handled safely (copy it by hand if needed)."
            continue
        fi
        DIR_NAMES+=("$name"); DIR_MODES+=("$mode"); names+=" $name"
    done <<<"$listing"

    if [[ ${#DIR_NAMES[@]} -eq 0 ]]; then
        echo "  No subdirectories found."
        COPY_DIRS=""; CREATE_EMPTY_DIRS="n"
        return 0
    fi

    declare -A sizes=()
    size_raw="$(rssh "cd '$SRC_PATH' && du -sh -- $names 2>/dev/null" || true)"
    while IFS=$'\t' read -r size name; do
        [[ -n "$name" ]] && sizes["$name"]="$size"
    done <<<"$size_raw"

    local ans
    if [[ -z "${COPY_DIRS+x}" ]]; then
        COPY_DIRS=""
        for name in "${DIR_NAMES[@]}"; do
            ans=""
            read -rp "    Copy '$name' (${sizes[$name]:-size unknown})? (y/n) [n]: " ans
            if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then COPY_DIRS+="$name "; fi
        done
        COPY_DIRS="${COPY_DIRS% }"
    else
        echo "  Directories to copy (preset): ${COPY_DIRS:-none}"
        local d found
        for d in $COPY_DIRS; do
            found=n
            for name in "${DIR_NAMES[@]}"; do [[ "$name" == "$d" ]] && found=y; done
            [[ "$found" == "y" ]] || die "Preset directory '$d' does not exist in $SRC_PATH on the source."
        done
    fi

    local notcopied=0
    for name in "${DIR_NAMES[@]}"; do dir_selected "$name" || notcopied=$((notcopied + 1)); done
    if [[ $notcopied -gt 0 ]]; then
        yn CREATE_EMPTY_DIRS "  Create the $notcopied directories that are not copied as empty directories on the target" "y"
    else
        CREATE_EMPTY_DIRS="n"
    fi
}

gather_nginx() {
    echo ""
    echo "--- Web app (nginx + gunicorn) ---"
    local slug_guess
    ask SRC_DOMAIN "Source domain" "" valid_domain;  SRC_DOMAIN="${SRC_DOMAIN,,}"
    slug_guess="$(slugify "$SRC_DOMAIN")"
    ask SRC_PATH "Source app path" "/home/$SRC_USER/$SRC_DOMAIN" valid_path
    ask SRC_SERVICE "Source gunicorn service file" "/etc/systemd/system/$slug_guess.service" valid_service_path
    ask SRC_NGINX "Source nginx config file" "/etc/nginx/sites-available/$slug_guess" valid_file_path

    echo "  Checking the source ..."
    rssh "test -d '$SRC_PATH'"  || die "Source path $SRC_PATH not found on the source server."
    SRC_SERVICE_TEXT="$(rssh "cat -- '$SRC_SERVICE'")" || die "Cannot read $SRC_SERVICE on the source server."
    SRC_NGINX_TEXT="$(rssh "cat -- '$SRC_NGINX'")"     || die "Cannot read $SRC_NGINX on the source server."
    [[ -n "$SRC_SERVICE_TEXT" && -n "$SRC_NGINX_TEXT" ]] || die "Source service or nginx file is empty."
    gather_dirs

    SRC_SLUG="$(basename "$SRC_SERVICE" .service)"
    local src_workers
    src_workers="$(grep -oE -- '--workers[[:space:]]+[0-9]+' <<<"$SRC_SERVICE_TEXT" | head -1 | awk '{print $2}' || true)"
    ask WORKERS "Number of gunicorn workers" "${src_workers:-2}" valid_workers

    echo "  (Same as the source domain = plain migration: no search & replace of names is done.)"
    ask TGT_DOMAIN "Target domain" "$SRC_DOMAIN" valid_domain;  TGT_DOMAIN="${TGT_DOMAIN,,}"
    TGT_SLUG="$(slugify "$TGT_DOMAIN")"

    SVC_USER="$(sed -n 's/^User=//p' <<<"$SRC_SERVICE_TEXT" | head -1)"
    ask TGT_PATH "Target app path" "/home/${SVC_USER:-$SRC_USER}/$TGT_DOMAIN" valid_path

    build_pairs
    SVC_TEXT="$(convert_text <<<"$SRC_SERVICE_TEXT" | set_workers "$WORKERS")"
    NGX_TEXT="$(convert_text <<<"$SRC_NGINX_TEXT")"
    SVC_USER="$(sed -n 's/^User=//p' <<<"$SVC_TEXT" | head -1)"

    # --- checks on the target, before anything is changed
    command -v nginx >/dev/null || die "nginx is not installed on this server (run ubuntu_provision.sh first)."
    ensure_service nginx "nginx" ENABLE_NGINX_SERVICE
    [[ -n "$SVC_USER" ]] || die "The source service has no User= line; refusing to run the clone as an unknown user."
    id "$SVC_USER" >/dev/null 2>&1 || die "User '$SVC_USER' (from the service file) does not exist on this server. Create it first."
    SVC_GROUP="$(id -gn "$SVC_USER")"
    local exe rel top n build_venv_preset="${BUILD_VENV:-}"
    EXISTING_EXE=""; BUILD_VENV="n"; VENV_DIR=""; PY_BIN=""
    exe="$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' <<<"$SVC_TEXT" | head -1)"
    if [[ "$exe" == "$TGT_PATH"/* ]]; then
        rel="${exe#"$TGT_PATH"/}"; top="${rel%%/*}"
        for n in "${DIR_NAMES[@]}"; do
            if [[ "$n" == "$top" ]] && ! dir_selected "$top"; then
                # The program the service starts is in a directory that will not be copied (typically venv/):
                # it must already be set up on the target, otherwise the service can never start.
                if [[ -x "$exe" ]]; then
                    EXISTING_EXE="$exe"
                    echo "  Found the existing program $exe on the target; the service will use it."
                else
                    echo ""
                    echo "  [!] The service starts $exe, which lives in '$top/' - a directory you chose not to copy."
                    echo "      It does not exist on this server yet."
                    if dir_selected server && rssh "test -f '$SRC_PATH/server/requirements.txt'"; then
                        BUILD_VENV="$build_venv_preset"
                        yn BUILD_VENV "  Build the virtual environment '$top' here from server/requirements.txt" "n"
                    else
                        echo "      (It cannot be built here: that needs 'server' copied and $SRC_PATH/server/requirements.txt on the source.)"
                    fi
                    if [[ "$BUILD_VENV" == "y" ]]; then
                        VENV_DIR="$TGT_PATH/$top"
                        resolve_python
                        echo "      Will use $PY_BIN ($("$PY_BIN" --version 2>&1))."
                        continue
                    fi
                    echo "      Set it up first, then re-run this script:"
                    echo "        sudo -u $SVC_USER mkdir -p $TGT_PATH"
                    echo "        sudo -u $SVC_USER python3 -m venv $TGT_PATH/$top      # same Python version as the source"
                    echo "        sudo -u $SVC_USER $TGT_PATH/$top/bin/pip install gunicorn gevent <the app's requirements>"
                    echo "        # and make sure $exe exists and is executable"
                    echo "        # (the service starts it; on the source it is a copy/link of gunicorn named after the service)"
                    echo "      Or answer 'y' for '$top' to copy it from the source (paths inside it are rewritten)."
                    die "Required program missing on the target. Nothing was changed."
                fi
            fi
        done
    fi
    [[ -d "$(dirname "$TGT_PATH")" ]] || die "Parent directory $(dirname "$TGT_PATH") does not exist on this server."

    TGT_SERVICE="/etc/systemd/system/$TGT_SLUG.service"
    TGT_NGINX="/etc/nginx/sites-available/$TGT_SLUG"
    OVERWRITE_OK=""
    local entry ename in_use=""
    if [[ -d "$TGT_PATH" ]]; then
        while IFS= read -r -d '' entry; do
            ename="${entry##*/}"
            # a directory that is not being copied (e.g. a venv prepared in advance, log/) is left alone
            if [[ -d "$entry" && ! -L "$entry" ]] && ! dir_selected "$ename"; then continue; fi
            in_use+="$ename "
        done < <(find "$TGT_PATH" -mindepth 1 -maxdepth 1 -print0)
    fi
    if [[ -n "$in_use" ]]; then
        echo "  [!] $TGT_PATH already contains: $in_use"
        echo "      rsync would merge into it (nothing is deleted)."
        yn OVERWRITE_PATH "  Copy into the existing directory anyway" n
        [[ "$OVERWRITE_PATH" == "y" ]] || die "Target path in use. Choose another path."
    fi
    for f in "$TGT_SERVICE" "$TGT_NGINX" "/etc/nginx/sites-enabled/$TGT_SLUG"; do
        if [[ -e "$f" || -L "$f" ]]; then
            echo "  [!] $f already exists (a backup is kept in /root/clone_backup_*)."
            yn OVERWRITE_OK "  Replace existing target files" n
            [[ "$OVERWRITE_OK" == "y" ]] || die "Existing target files would be replaced. Aborting."
            break
        fi
    done

    # Files named after the source slug that are renamed inside the copied tree
    RENAME_LIST=""
    if [[ "$SRC_SLUG" != "$TGT_SLUG" ]]; then
        local roots=""
        dir_selected venv   && roots+=" '$SRC_PATH/venv/bin'"
        dir_selected server && roots+=" '$SRC_PATH/server/wsgi'"
        if [[ -n "$roots" ]]; then
            RENAME_LIST="$(rssh "find $roots -maxdepth 1 -name '${SRC_SLUG}*' ! -name '*.sock' ! -name '*.pid' 2>/dev/null" || true)"
        fi
    fi

    if grep -q 'ssl_certificate' <<<"$NGX_TEXT"; then
        NGINX_USES_SSL=y
    else
        NGINX_USES_SSL=n
    fi
    ISSUE_CERT="${ISSUE_CERT:-}"
    if [[ "$NGINX_USES_SSL" == "y" ]]; then
        if [[ -f "/etc/letsencrypt/live/$TGT_DOMAIN/fullchain.pem" ]]; then
            echo "  A Let's Encrypt certificate for $TGT_DOMAIN already exists here; it will be reused."
            ISSUE_CERT="n"; CERT_EXISTS=y
        else
            CERT_EXISTS=n
            yn ISSUE_CERT "Obtain a Let's Encrypt certificate for $TGT_DOMAIN (uses a temporary HTTP-only nginx site)" "y"
            if [[ "$ISSUE_CERT" == "y" ]]; then
                gather_cert
            else
                die "The nginx config needs a certificate for $TGT_DOMAIN and none exists. Aborting (fail closed)."
            fi
        fi
    else
        ISSUE_CERT="n"; CERT_EXISTS=n
        echo "  The source nginx config uses no TLS certificate; none will be requested."
    fi
    yn START_SERVICE "Start the gunicorn service when done" "y"
}

gather_cert() {
    local ips resolved
    ips="$(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')"
    resolved="$(getent ahosts "$TGT_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
    echo "  $TGT_DOMAIN resolves to: ${resolved:-nothing}"
    echo "  This server's addresses: ${ips:-unknown}"
    local match=n a
    for a in $resolved; do [[ " $ips " == *" $a "* ]] && match=y; done
    if [[ "$match" != "y" ]]; then
        echo "  [!] The domain does not resolve to an address on this server (fine behind NAT/proxy, fatal otherwise)."
        echo "      Let's Encrypt must reach this server on port 80 using that name."
        yn DNS_OK "  Continue anyway" n
        [[ "$DNS_OK" == "y" ]] || die "Fix DNS for $TGT_DOMAIN first."
    fi
    if compgen -G "/etc/letsencrypt/accounts/*" >/dev/null; then
        ask_optional LE_EMAIL "Let's Encrypt contact email (blank = reuse existing account)" valid_email
    else
        ask LE_EMAIL "Let's Encrypt contact email (needed for the new account)" "" valid_email
    fi
    yn LE_STAGING "Use the Let's Encrypt STAGING server (test run, browsers will not trust the certificate)" "n"
    echo "  Continuing means you accept the Let's Encrypt subscriber agreement (certbot --agree-tos)."
}

gather_mysql() {
    echo ""
    echo "--- MySQL schema ---"
    ensure_local_db
    ask SRC_DB_SCHEMA "Source schema" "" valid_db_schema
    ask SRC_DB_USER "Source DB username" "" valid_db_user
    ask_secret SRC_DB_PASS "Source DB password"
    ask TGT_DB_SCHEMA "Target schema" "$SRC_DB_SCHEMA" valid_db_schema
    ask TGT_DB_USER "Target DB username" "$SRC_DB_USER" valid_db_user
    ask_secret TGT_DB_PASS "Target DB password"

    echo "  Checking source database access ..."
    rssh "command -v mysqldump >/dev/null" || die "mysqldump is not installed on the source server."
    SRC_DB_CHARSET="$(src_mysql "mysql --defaults-extra-file=\"\$CNF\" -N -B -e \"SELECT default_character_set_name, default_collation_name FROM information_schema.schemata WHERE schema_name='$SRC_DB_SCHEMA'\"")" \
        || die "Could not log in to the source MySQL as '$SRC_DB_USER' (wrong password, or the user may not connect from localhost)."
    [[ -n "$SRC_DB_CHARSET" ]] || die "Schema '$SRC_DB_SCHEMA' not visible to '$SRC_DB_USER' on the source."
    SRC_DB_CS="$(awk '{print $1}' <<<"$SRC_DB_CHARSET")"
    SRC_DB_COLL="$(awk '{print $2}' <<<"$SRC_DB_CHARSET")"
    [[ "$SRC_DB_CS" =~ ^[a-z0-9_]+$ && "$SRC_DB_COLL" =~ ^[a-z0-9_]+$ ]] || die "Unexpected charset/collation from the source."
    echo "  Source schema charset: $SRC_DB_CS / $SRC_DB_COLL"

    echo "  Checking the target database ..."
    local tables users
    tables="$(mysql_root -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$TGT_DB_SCHEMA'")"
    DB_USER_EXISTS=n
    users="$(mysql_root -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE user='$TGT_DB_USER' AND host='localhost'")"
    if [[ "$users" != "0" ]]; then
        DB_USER_EXISTS=y
        # Never change the password of an existing account: it must already match what you entered
        mysql --defaults-extra-file="$(tgt_user_cnf)" -N -B -e 'SELECT 1' >/dev/null 2>&1 \
            || die "User '$TGT_DB_USER'@'localhost' exists here but the password you entered does not work. Not changing it; use the correct password or another user name."
        echo "  Target user '$TGT_DB_USER' exists and the password works; it will be granted the target schema only."
    fi
    if [[ "$tables" != "0" ]]; then
        echo "  [!] Target schema '$TGT_DB_SCHEMA' already has $tables table(s). Importing REPLACES tables with the same names."
        local confirm=""
        read -rp "  Type 'overwrite' to continue, anything else aborts: " confirm
        [[ "$confirm" == "overwrite" ]] || die "Target schema in use. Aborting."
    fi
}

gather_cron() {
    echo ""
    echo "--- Cron jobs ---"
    ask SRC_CRON_USER "Cron user on the source" "$SRC_USER" valid_user
    ask TGT_CRON_USER "Cron user on this server" "$SRC_CRON_USER" valid_user
    id "$TGT_CRON_USER" >/dev/null 2>&1 || die "User '$TGT_CRON_USER' does not exist on this server."
    if [[ -f /etc/cron.allow ]] && ! grep -qx "$TGT_CRON_USER" /etc/cron.allow; then
        echo "  [!] /etc/cron.allow exists and does not list '$TGT_CRON_USER': crontab -u would be refused and jobs would not run."
        echo "      Add the user to /etc/cron.allow first if that is intended."
        yn CRON_ALLOW_OK "  Continue anyway" n
        [[ "$CRON_ALLOW_OK" == "y" ]] || die "Fix /etc/cron.allow first."
    fi

    local raw
    if [[ "$SRC_CRON_USER" == "$SRC_USER" ]]; then
        raw="$(rssh "crontab -l" 2>&1 || true)"
    else
        raw="$(rssh "sudo -n crontab -u '$SRC_CRON_USER' -l" 2>&1 || true)"
    fi
    if grep -qiE 'password is required|not allowed to execute|may not run sudo' <<<"$raw"; then
        die "Cannot read the crontab of '$SRC_CRON_USER' (needs passwordless sudo for $SRC_USER on the source)."
    fi
    if [[ -z "$raw" || "$raw" == no\ crontab\ for* ]]; then
        echo "  The source has no crontab for '$SRC_CRON_USER'."
        CRON_SELECTED=()
        return 0
    fi

    build_pairs_if_needed
    local lines line conv ans
    CRON_SELECTED=()
    mapfile -t lines <<<"$raw"
    echo "  Confirm each job. Paths and domain names are replaced as shown."
    for line in "${lines[@]}"; do
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
        conv="$(printf '%s\n' "$line" | convert_text)"
        conv="${conv%$'\n'}"
        echo ""
        echo "    source: $line"
        if [[ "$conv" != "$line" ]]; then echo "    target: $conv"; else echo "    target: (unchanged)"; fi
        ans=""
        read -rp "    Clone this job? (y/n) [n]: " ans
        if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then CRON_SELECTED+=("$conv"); fi
    done
    echo ""
    echo "  ${#CRON_SELECTED[@]} job(s) selected."
}

# Cron replacements need the pairs even when only cron (no web app) is cloned
build_pairs_if_needed() {
    if [[ "${CLONE_NGINX:-n}" == "y" ]]; then return 0; fi
    echo "  No web app is cloned, so paths/domains in the jobs are replaced only if you give them now."
    ask_optional SRC_DOMAIN "Source domain to replace (blank = none)" valid_domain
    ask_optional TGT_DOMAIN "Target domain (blank = none)" valid_domain
    ask_optional SRC_PATH "Source path to replace (blank = none)" valid_path
    ask_optional TGT_PATH "Target path (blank = none)" valid_path
    SRC_SLUG="$(slugify "${SRC_DOMAIN:-}")"; TGT_SLUG="$(slugify "${TGT_DOMAIN:-}")"
    SRC_DOMAIN="${SRC_DOMAIN,,}"; TGT_DOMAIN="${TGT_DOMAIN,,}"
    build_pairs
}

## Summary and saved answers
## --------------------------------------------

print_summary() {
    echo ""
    echo "=========================================================="
    echo "Planned actions (nothing has been changed yet)"
    echo "=========================================================="
    echo "Source server           : $SRC_USER@$SRC_HOST:$SRC_PORT"
    echo "Clone web app?          : $CLONE_NGINX"
    if [[ "$CLONE_NGINX" == "y" ]]; then
        echo "  Source domain / path  : $SRC_DOMAIN  $SRC_PATH"
        echo "  Target domain / path  : $TGT_DOMAIN  $TGT_PATH"
        echo "  Directories copied    : ${COPY_DIRS:-none} (plus files directly in the path)"
        if [[ -n "${EXISTING_EXE:-}" ]]; then echo "  Existing program used : $EXISTING_EXE (set up in advance, not copied)"; fi
        if [[ "$BUILD_VENV" == "y" ]]; then
            echo "  Virtual environment   : build $VENV_DIR with $PY_BIN from server/requirements.txt (+ requirements_project.txt, constraints.txt if present)"
        fi
        local n skipped=""
        for n in "${DIR_NAMES[@]}"; do dir_selected "$n" || skipped+="$n "; done
        echo "  Directories NOT copied: ${skipped:-none}${skipped:+ (created empty: ${CREATE_EMPTY_DIRS})}"
        echo "  rsync excludes        : log/ contents, *.sock, *.pid   (no --delete)"
        if [[ "$SRC_DOMAIN" != "$TGT_DOMAIN" ]]; then
            echo "  Search & replace      : in the copied files, $SRC_DOMAIN -> $TGT_DOMAIN and ${SRC_SLUG} -> ${TGT_SLUG} (plus the path)"
        else
            echo "  Search & replace      : none (same domain)"
        fi
        echo "  Service               : $SRC_SERVICE -> $TGT_SERVICE (workers: $WORKERS, runs as $SVC_USER)"
        echo "  nginx site            : $SRC_NGINX -> $TGT_NGINX (+ symlink in sites-enabled)"
        if [[ -n "$RENAME_LIST" ]]; then
            echo "  Files renamed ($SRC_SLUG* -> $TGT_SLUG*):"
            sed "s|^|    |" <<<"$RENAME_LIST"
        fi
        if [[ "$ISSUE_CERT" == "y" ]]; then
            echo "  Let's Encrypt         : request for $TGT_DOMAIN via temporary HTTP-only nginx site (staging: $LE_STAGING)"
        elif [[ "${CERT_EXISTS:-n}" == "y" ]]; then
            echo "  Let's Encrypt         : existing certificate reused"
        fi
        echo "  Start service         : $START_SERVICE"
    fi
    echo "Clone MySQL schema?     : $CLONE_MYSQL"
    if [[ "$CLONE_MYSQL" == "y" ]]; then
        echo "  Source                : $SRC_DB_SCHEMA (user $SRC_DB_USER, password: [provided])"
        echo "  Local MySQL root login: $([[ -n "$TGT_ROOT_CNF" ]] && echo 'password [provided]' || echo 'unix socket')"
        echo "  Target                : $TGT_DB_SCHEMA (user $TGT_DB_USER@localhost, password: [provided]; existing user: $DB_USER_EXISTS)"
    fi
    echo "Clone cron jobs?        : $CLONE_CRON"
    if [[ "$CLONE_CRON" == "y" ]]; then
        echo "  Target user           : $TGT_CRON_USER ($(( ${#CRON_SELECTED[@]} )) job(s))"
    fi
    echo ""
}

# Same role as save_config in ubuntu_provision.sh (optional file name, passwords never written).
# It writes an explicit list of answer variables instead of grepping all prefixed variables: this
# script also keeps derived values with the same prefixes (e.g. the source service/nginx file text).
save_config() {
    local config_output_file="${1:-clone_${TS}.conf}" v
    ( umask 077
      {
        echo "# ubuntu_clone_server.sh configuration saved $(date '+%F %T') (passwords and cron lines are never saved)"
        for v in SRC_HOST SRC_PORT SRC_USER SRC_KEY CLONE_NGINX SRC_DOMAIN SRC_PATH SRC_SERVICE SRC_NGINX \
                 WORKERS TGT_DOMAIN TGT_PATH COPY_DIRS CREATE_EMPTY_DIRS ISSUE_CERT LE_EMAIL LE_STAGING START_SERVICE \
                 ENABLE_NGINX_SERVICE ENABLE_DB_SERVICE BUILD_VENV PYTHON_VERSION CLONE_MYSQL \
                 SRC_DB_SCHEMA SRC_DB_USER TGT_DB_SCHEMA TGT_DB_USER CLONE_CRON SRC_CRON_USER TGT_CRON_USER; do
            if [[ -n "${!v+x}" ]]; then printf '%s=%q\n' "$v" "${!v}"; fi
        done
      } > "$config_output_file" ) || return 1
    # the file is created by root; give it to the user who ran sudo so it can be edited without sudo
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then chown "$SUDO_UID:$SUDO_GID" -- "$config_output_file" 2>/dev/null || true; fi
    echo "  Configuration parameters written to '$config_output_file'. "
}

# A config file is sourced as root, so refuse one that anybody else could have modified.
check_conf_safe() {
    local f="$1" owner mode
    owner="$(stat -c %u -- "$f")"; mode="$(stat -c %a -- "$f")"
    if [[ "$owner" != "0" && "$owner" != "${SUDO_UID:-0}" ]]; then
        die "Config file '$f' is owned by uid $owner, not by root or the user running sudo. Refusing to load it."
    fi
    if (( (8#$mode & 8#022) != 0 )); then
        die "Config file '$f' is writable by group/others (mode $mode). Run: chmod go-w '$f'"
    fi
}

## Execute phase
## --------------------------------------------

# Finds the interpreter for the virtual environment. Fails closed: a requested version that is not installed
# aborts; there is no fallback to another Python.
resolve_python() {
    local name="python3"
    if [[ -n "${PYTHON_VERSION:-}" ]]; then
        valid_python_version "$PYTHON_VERSION" || die "Invalid PYTHON_VERSION '$PYTHON_VERSION'."
        name="python$PYTHON_VERSION"
    fi
    PY_BIN="$(command -v "$name" || true)"
    [[ -n "$PY_BIN" ]] || die "$name is not installed on this server (PYTHON_VERSION='${PYTHON_VERSION:-}', empty = system python3)."
    "$PY_BIN" -c 'import venv, ensurepip' 2>/dev/null \
        || die "$PY_BIN cannot create virtual environments (install the matching python3-venv / ${name}-venv package)."
}

# Builds VENV_DIR from server/requirements.txt (+ requirements_project.txt, constraints.txt if present) as the
# service user, then adds the gunicorn link the service file starts if that name is missing.
build_venv() {
    local srv="$TGT_PATH/server" home pip exe reqs=(-r requirements.txt) cons=() runas
    home="$(getent passwd "$SVC_USER" | cut -d: -f6)"
    [[ -n "$home" && -d "$home" ]] || die "Home directory of $SVC_USER not found."
    if [[ ! -f "$srv/requirements.txt" ]]; then
        echo "  [!] $srv/requirements.txt is missing - virtual environment NOT built."
        return 0
    fi
    [[ -f "$srv/requirements_project.txt" ]] && reqs+=(-r requirements_project.txt)
    [[ -f "$srv/constraints.txt" ]] && cons=(-c constraints.txt)
    runas=(runuser -u "$SVC_USER" -- env HOME="$home")
    echo "  Building $VENV_DIR with $PY_BIN ..."
    ( cd "$srv" && "${runas[@]}" "$PY_BIN" -m venv "$VENV_DIR" ) || die "Creating the virtual environment failed."
    pip=("$VENV_DIR/bin/python" -m pip)
    ( cd "$srv" \
        && "${runas[@]}" "${pip[@]}" install --upgrade pip \
        && "${runas[@]}" "${pip[@]}" install wheel pipdeptree \
        && "${runas[@]}" "${pip[@]}" install "${reqs[@]}" "${cons[@]}" ) \
        || die "pip install failed. The virtual environment is left in $VENV_DIR for inspection; nothing was deleted."
    echo "  Installed: ${reqs[*]} ${cons[*]}"

    exe="$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' <<<"$SVC_TEXT" | head -1)"
    if [[ "$exe" == "$VENV_DIR/bin/"* && ! -e "$exe" && ! -L "$exe" ]]; then
        if [[ -x "$VENV_DIR/bin/gunicorn" ]]; then
            "${runas[@]}" ln -s gunicorn "$exe"
            echo "  Linked ${exe#"$TGT_PATH"/} -> gunicorn"
        else
            echo "  [!] $VENV_DIR/bin/gunicorn not found (is gunicorn in the requirements?) - $exe not created."
        fi
    fi
}

step_app_files() {
    echo ""
    echo "--- Copy the app ---"
    command -v rsync >/dev/null || { echo "  Installing rsync ..."; DEBIAN_FRONTEND=noninteractive apt-get install -y rsync; }
    install -d -o "$SVC_USER" -g "$SVC_GROUP" -- "$TGT_PATH"
    # Only the chosen top-level directories are copied: every other top-level directory is excluded
    # (including ones that appear on the source later), files directly in the path are copied.
    local filters=(--exclude='/log/*' --exclude='*.sock' --exclude='*.pid') d
    for d in $COPY_DIRS; do filters+=(--include="/$d/"); done
    filters+=(--exclude='/*/')
    rsync -a --partial --info=stats1 "${filters[@]}" \
        -e "$RSYNC_SSH" "$SRC_USER@$SRC_HOST:$SRC_PATH/" "$TGT_PATH/"
    echo "  Copied $SRC_PATH -> $TGT_PATH (directories: ${COPY_DIRS:-none})"
    install -d -o "$SVC_USER" -g "$SVC_GROUP" -- "$TGT_PATH/log"
    if [[ "${CREATE_EMPTY_DIRS:-n}" == "y" ]]; then
        local i
        for i in "${!DIR_NAMES[@]}"; do
            d="${DIR_NAMES[$i]}"
            if dir_selected "$d"; then continue; fi
            if [[ -e "$TGT_PATH/$d" || -L "$TGT_PATH/$d" ]]; then
                echo "  $d already exists on the target (set up in advance), left unchanged."
            else
                install -d -o "$SVC_USER" -g "$SVC_GROUP" -m "${DIR_MODES[$i]}" -- "$TGT_PATH/$d"
                echo "  Created empty directory $d (mode ${DIR_MODES[$i]})"
            fi
        done
    fi

    fix_tree_paths "$TGT_PATH" "$SRC_PATH" "$TGT_PATH"

    if [[ "$SRC_DOMAIN" != "$TGT_DOMAIN" ]]; then
        echo "  Replacing names in the copied files (domain and name, dot and underscore forms) ..."
        local pi
        for (( pi = 0; pi < ${#PAIRS[@]}; pi += 2 )); do echo "    ${PAIRS[pi]} -> ${PAIRS[pi+1]}"; done
        replace_in_tree "$TGT_PATH"
    else
        echo "  Source and target domain are the same: no search & replace of names."
    fi

    if [[ "$SRC_SLUG" != "$TGT_SLUG" ]]; then
        local d f base new
        for d in "$TGT_PATH/venv/bin" "$TGT_PATH/server/wsgi"; do
            [[ -d "$d" ]] || continue
            while IFS= read -r -d '' f; do
                base="${f##*/}"
                new="$d/${TGT_SLUG}${base#"$SRC_SLUG"}"
                if [[ -e "$new" || -L "$new" ]]; then
                    echo "  [!] $new exists, not renaming $f"
                else
                    mv -- "$f" "$new"
                    echo "  Renamed ${f#"$TGT_PATH"/} -> ${new#"$TGT_PATH"/}"
                fi
            done < <(find "$d" -maxdepth 1 -name "${SRC_SLUG}*" ! -name '*.sock' ! -name '*.pid' -print0)
        done
    fi

    if [[ "$BUILD_VENV" == "y" ]]; then build_venv; fi
}

step_service() {
    echo ""
    echo "--- gunicorn service ---"
    backup_file "$TGT_SERVICE"
    printf '%s\n' "$SVC_TEXT" > "$TGT_SERVICE"
    chmod 644 "$TGT_SERVICE"
    systemctl daemon-reload
    systemctl enable "$TGT_SLUG.service" >/dev/null 2>&1
    echo "  Installed $TGT_SERVICE and enabled it at boot."
    local exe
    exe="$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$TGT_SERVICE" | head -1)"
    if [[ -n "$exe" && ! -x "$exe" ]]; then
        echo "  [!] ExecStart binary $exe is missing or not executable: the service will not start until that is fixed."
        SERVICE_FIXABLE=n
    else
        SERVICE_FIXABLE=y
    fi
    if [[ "${CLONE_MYSQL:-n}" == "y" ]]; then
        local hits="" pat
        local gopts=(-rIlF --exclude-dir=venv --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=log --exclude-dir=static)
        for pat in "$SRC_DB_SCHEMA" "$SRC_DB_USER" "$SRC_DB_PASS"; do
            hits+="$(grep "${gopts[@]}" -- "$pat" "$TGT_PATH" 2>/dev/null || true)"$'\n'
        done
        hits="$(printf '%s' "$hits" | sed '/^$/d' | sort -u)"
        if [[ -n "$hits" ]]; then
            echo "  Files in the copied app that mention the source DB schema, user or password"
            echo "  (update them by hand if they hold the connection settings; the target names/password differ):"
            sed 's/^/    /' <<<"$hits"
        else
            echo "  No file in the copied app mentions the source DB schema, user or password."
        fi
    fi
}

step_mysql() {
    echo ""
    echo "--- MySQL schema ---"
    local dump="$TMP_DIR/dump.sql" err="$TMP_DIR/dump.err" opts="--single-transaction --routines --triggers"
    echo "  Dumping $SRC_DB_SCHEMA from the source ..."
    if ! src_mysql "mysqldump --defaults-extra-file=\"\$CNF\" $opts --no-tablespaces $SRC_DB_SCHEMA" > "$dump" 2> "$err"; then
        if grep -qi 'unknown option' "$err"; then
            src_mysql "mysqldump --defaults-extra-file=\"\$CNF\" $opts $SRC_DB_SCHEMA" > "$dump" 2> "$err" \
                || { cat "$err"; die "mysqldump failed."; }
        else
            cat "$err"; die "mysqldump failed."
        fi
    fi
    tail -n 3 "$dump" | grep -q 'Dump completed' || die "The dump looks incomplete (no completion marker). Nothing was imported."
    echo "  Dump size: $(du -h "$dump" | cut -f1)"

    local pw; pw="$(sql_escape "$TGT_DB_PASS")"
    local grant_schema="${TGT_DB_SCHEMA//_/\\_}"   # '_' is a wildcard in GRANT database names
    echo "  Creating schema and user on this server ..."
    mysql_root <<SQL
CREATE DATABASE IF NOT EXISTS \`$TGT_DB_SCHEMA\` CHARACTER SET $SRC_DB_CS COLLATE $SRC_DB_COLL;
CREATE USER IF NOT EXISTS '$TGT_DB_USER'@'localhost' IDENTIFIED BY '$pw';
GRANT ALL PRIVILEGES ON \`$grant_schema\`.* TO '$TGT_DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
    echo "  Importing ..."
    mysql_root "$TGT_DB_SCHEMA" < "$dump"
    local n
    n="$(mysql_root -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$TGT_DB_SCHEMA'")"
    echo "  Imported: $n table(s) now in $TGT_DB_SCHEMA."
    rm -f -- "$dump"
}

nginx_apply() { nginx -t && systemctl reload nginx; }

step_nginx_site() {
    echo ""
    echo "--- nginx site ---"
    backup_file "$TGT_NGINX"
    backup_file "/etc/nginx/sites-enabled/$TGT_SLUG"
    printf '%s\n' "$NGX_TEXT" > "$TMP_DIR/site.final"

    if [[ "$ISSUE_CERT" == "y" ]]; then
        echo "  Installing certbot ..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx >/dev/null

        echo "  Writing a temporary HTTP-only site for $TGT_DOMAIN (the copied config needs a certificate that does not exist yet) ..."
        {
            echo "# Temporary site for the Let's Encrypt challenge, replaced by the cloned config"
            echo "server {"
            echo "    listen 80;"
            if [[ -d /proc/sys/net/ipv6 && "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" == "0" ]]; then
                echo "    listen [::]:80;"
            fi
            echo "    server_name $TGT_DOMAIN;"
            echo "    location / { return 404; }"
            echo "}"
        } > "$TGT_NGINX"
        ln -sfn "$TGT_NGINX" "/etc/nginx/sites-enabled/$TGT_SLUG"
        nginx_apply || die "nginx rejects even the temporary site; fix the existing nginx config first."

        local args=(certonly --nginx -d "$TGT_DOMAIN" --non-interactive --agree-tos)
        if [[ -n "${LE_EMAIL:-}" ]]; then args+=(-m "$LE_EMAIL"); fi
        if ! compgen -G "/etc/letsencrypt/accounts/*" >/dev/null && [[ -z "${LE_EMAIL:-}" ]]; then
            die "No Let's Encrypt account and no email given."
        fi
        if [[ "${LE_STAGING:-n}" == "y" ]]; then args+=(--staging); fi
        echo "  Requesting the certificate ..."
        if ! certbot "${args[@]}"; then
            echo "  [!] Certificate request failed. The temporary HTTP-only site stays active; the cloned config was NOT enabled."
            echo "      Check DNS and that ports 80/443 are open (ufw), then re-run, or run: certbot ${args[*]}"
            NGINX_FAILED=1
            return 0
        fi
        [[ -f "/etc/letsencrypt/live/$TGT_DOMAIN/fullchain.pem" ]] || die "certbot reported success but the certificate is missing."
    fi

    cp -- "$TMP_DIR/site.final" "$TGT_NGINX"
    chmod 644 "$TGT_NGINX"
    ln -sfn "$TGT_NGINX" "/etc/nginx/sites-enabled/$TGT_SLUG"
    if ! nginx_apply; then
        echo "  [!] nginx rejects the cloned config (see the error above)."
        if [[ "$ISSUE_CERT" == "y" ]]; then
            # fall back to the working temporary site instead of leaving nginx broken
            printf 'server {\n    listen 80;\n    server_name %s;\n    location / { return 404; }\n}\n' "$TGT_DOMAIN" > "$TGT_NGINX"
            nginx_apply || true
        else
            rm -f -- "/etc/nginx/sites-enabled/$TGT_SLUG"
            nginx_apply || true
        fi
        echo "  A copy of the cloned config is saved as $TGT_NGINX.cloned"
        cp -- "$TMP_DIR/site.final" "$TGT_NGINX.cloned"
        echo "  Typical causes: the same 'map', 'upstream' or 'limit_req_zone' name is already defined by another site here."
        NGINX_FAILED=1
        return 0
    fi
    echo "  nginx site $TGT_SLUG is active."
}

step_start_service() {
    echo ""
    echo "--- Start service ---"
    if [[ "${START_SERVICE:-n}" != "y" ]]; then echo "  Not started (as requested). Start it with: systemctl start $TGT_SLUG"; return 0; fi
    if [[ "${SERVICE_FIXABLE:-y}" != "y" ]]; then echo "  Not started: ExecStart binary is missing (see above)."; return 0; fi
    systemctl start "$TGT_SLUG.service" || true
    sleep 2
    if systemctl is-active --quiet "$TGT_SLUG.service"; then
        echo "  $TGT_SLUG.service is running."
    else
        echo "  [!] $TGT_SLUG.service is not running. Check: journalctl -u $TGT_SLUG -n 50 --no-pager"
    fi
}

step_cron() {
    echo ""
    echo "--- Cron jobs ---"
    if [[ ${#CRON_SELECTED[@]} -eq 0 ]]; then echo "  No jobs selected."; return 0; fi
    local cur="$TMP_DIR/cron.cur" new="$TMP_DIR/cron.new" line added=0
    crontab -u "$TGT_CRON_USER" -l > "$cur" 2>/dev/null || : > "$cur"
    if [[ -s "$cur" ]]; then
        backup_file_content "$cur" "crontab_$TGT_CRON_USER"
    fi
    cp -- "$cur" "$new"
    {
        echo "# cloned from $SRC_USER@$SRC_HOST on $(date +%F)"
    } > "$TMP_DIR/cron.head"
    local body=""
    for line in "${CRON_SELECTED[@]}"; do
        if grep -qxF -- "$line" "$cur"; then
            echo "  Already present, skipped: $line"
        else
            body+="$line"$'\n'
            added=$((added + 1))
        fi
    done
    if [[ $added -gt 0 ]]; then
        { cat "$TMP_DIR/cron.head"; printf '%s' "$body"; } >> "$new"
        crontab -u "$TGT_CRON_USER" "$new"
        echo "  Added $added job(s) to the crontab of $TGT_CRON_USER."
    else
        echo "  Nothing to add."
    fi
}

backup_file_content() {
    if [[ -z "$BACKUP_DIR" ]]; then BACKUP_DIR="/root/clone_backup_$TS"; install -d -m 700 "$BACKUP_DIR"; fi
    cp -- "$1" "$BACKUP_DIR/$2"
}

## Main
## --------------------------------------------

main() {
    if [ "$EUID" -ne 0 ]; then die "Please run as root (sudo)."; fi
    umask 022
    TMP_DIR="$(mktemp -d)"
    trap cleanup EXIT
    trap 'on_error $LINENO' ERR
    trap on_ctrl_c SIGINT
    trap 'on_ctrl_c 143 "Terminated."' TERM     # not in ubuntu_provision.sh: also keep the answers on kill / closed terminal
    trap 'on_ctrl_c 129 "Terminal closed."' HUP

    local conf="" cli_python=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --python)   [[ -n "${2:-}" ]] || die "--python needs a version, e.g. --python 3.14"; cli_python="$2"; shift 2 ;;
            --python=*) cli_python="${1#--python=}"; shift ;;
            -*)         die "Unknown option '$1'." ;;
            *)          [[ -z "$conf" ]] || die "Only one config file can be given."; conf="$1"; shift ;;
        esac
    done
    [[ -z "$cli_python" ]] || valid_python_version "$cli_python" || die "Invalid --python value."
    if [[ -n "$conf" ]]; then
        [[ -f "$conf" ]] || die "Config file '$conf' not found."
        check_conf_safe "$conf"
        # shellcheck disable=SC1090
        source "$conf"
        echo "Loaded answers from $conf (anything missing is asked; passwords are always asked)"
    fi
    if [[ -n "$cli_python" ]]; then PYTHON_VERSION="$cli_python"; fi   # the command line wins over the .conf file
    if [[ -n "$PYTHON_VERSION" ]]; then valid_python_version "$PYTHON_VERSION" || die "Invalid PYTHON_VERSION '$PYTHON_VERSION'."; fi

    LOG_FILE="/var/log/ubuntu_clone_server_$TS.log"
    ( umask 077; : > "$LOG_FILE" )
    exec > >(tee -a "$LOG_FILE") 2>&1

    echo "Xlvisuals Ubuntu server clone"
    echo "Started: $(date)"
    echo "Logging to: $LOG_FILE (passwords are never written to it)"
    command -v python3 >/dev/null || die "python3 is required."
    command -v ssh >/dev/null && command -v ssh-keygen >/dev/null && command -v ssh-keyscan >/dev/null \
        || die "OpenSSH client tools are required."

    gather_ssh

    yn CLONE_NGINX "Would you like to clone the nginx web app?" "n"
    [[ "$CLONE_NGINX" == "y" ]] && gather_nginx
    yn CLONE_MYSQL "Would you like to clone a MySQL schema?" "n"
    [[ "$CLONE_MYSQL" == "y" ]] && gather_mysql
    yn CLONE_CRON "Would you like to clone cron jobs?" "n"
    [[ "$CLONE_CRON" == "y" ]] && gather_cron

    if [[ "$CLONE_NGINX" != "y" && "$CLONE_MYSQL" != "y" && "$CLONE_CRON" != "y" ]]; then
        echo "Nothing selected."
        exit 0
    fi

    print_summary
    save_config "clone_${TS}.conf"
    echo "  To repeat this clone later: sudo bash ubuntu_clone_server.sh clone_${TS}.conf"
    local go=""
    yn go "Proceed with the clone?" "n"
    [[ "$go" == "y" ]] || { echo "Aborted by user. Nothing was changed."; exit 0; }

    NGINX_FAILED=0
    local failed=0
    EXECUTING="y"
    if [[ "$CLONE_NGINX" == "y" ]]; then
        step_app_files
        step_service
    fi
    if [[ "$CLONE_MYSQL" == "y" ]]; then step_mysql; fi
    if [[ "$CLONE_NGINX" == "y" ]]; then
        step_start_service
        step_nginx_site
        failed="$NGINX_FAILED"
    fi
    if [[ "$CLONE_CRON" == "y" ]]; then step_cron; fi

    echo ""
    echo "=========================================================="
    if [[ "$failed" == "0" ]]; then echo "Clone finished."; else echo "Clone finished WITH PROBLEMS (see [!] above)."; fi
    if [[ "$CLONE_NGINX" == "y" && "$failed" == "0" ]]; then
        local code
        code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$TGT_DOMAIN:443:127.0.0.1" "https://$TGT_DOMAIN/" 2>/dev/null || true)"
        echo "Local check https://$TGT_DOMAIN/ -> HTTP ${code:-none}"
    fi
    [[ -n "$BACKUP_DIR" ]] && echo "Backups of replaced files: $BACKUP_DIR"
    echo "Still to do by hand: database settings inside the copied app (see the list above), DNS if not yet pointing here,"
    echo "firewall for ports 80/443, and any cron jobs that embed credentials."
    exit "$failed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
