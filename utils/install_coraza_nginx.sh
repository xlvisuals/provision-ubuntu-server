#!/usr/bin/env bash
# install_coraza_nginx.sh — build and install the Coraza WAF (with the OWASP Core Rule Set) as a
# dynamic module for the distro's nginx package. No Docker; everything is compiled from source.
#
# Usage:
#   sudo ./install_coraza_nginx.sh            # install, or rebuild after an nginx upgrade
#   sudo ./install_coraza_nginx.sh check      # report status; exit 1 if the module and nginx don't match
#   sudo ./install_coraza_nginx.sh detect     # WAF only logs (SecRuleEngine DetectionOnly) - the default after install
#   sudo ./install_coraza_nginx.sh enforce    # WAF blocks (SecRuleEngine On)
#   sudo ./install_coraza_nginx.sh --auto     # rebuild only if the module no longer fits nginx (used by the apt hook)
#
# What it does:
#   1. Builds libcoraza (Go -> C shared library) and installs it to /usr/local/lib
#   2. Builds the coraza-nginx connector against the *installed* nginx version, using the same
#      configure flags as the Ubuntu package, and installs it as a dynamic module
#   3. Installs the OWASP Core Rule Set into /etc/nginx/coraza/ (your edits there are preserved)
#   4. Sets up an audit log (JSON), logrotate, a Wazuh log monitor, and an apt hook that rebuilds
#      the module when nginx is upgraded to a new version
#
# The module is loaded but does nothing until a site enables it:
#       coraza on;
#       coraza_rules_file /etc/nginx/coraza/coraza-nginx.conf;
#
# Override versions with environment variables, e.g.  CRS_TAG=v4.30.0 sudo -E ./install_coraza_nginx.sh
#
set -euo pipefail

LIBCORAZA_TAG="${LIBCORAZA_TAG:-v1.8.0}"        # needs >= 1.7.0 for coraza-nginx
CORAZA_NGINX_TAG="${CORAZA_NGINX_TAG:-v0.21.0}"
CRS_TAG="${CRS_TAG:-v4.29.0}"
MIN_GO="1.25"                                   # libcoraza requires Go >= 1.25

CORAZA_DIR="/etc/nginx/coraza"
AUDIT_LOG="/var/log/nginx/coraza_audit.json"    # not *.log on purpose: the stock nginx logrotate would
                                                # rotate it with USR1, which Coraza does not honour
STATE_DIR="/var/lib/coraza-nginx"
STAMP_FILE="$STATE_DIR/build.stamp"
SELF_INSTALL_PATH="/usr/local/sbin/install_coraza_nginx.sh"
MODULES_ENABLED_CONF="/etc/nginx/modules-enabled/50-mod-http-coraza.conf"
BUILD_LOG="/var/log/coraza-nginx-build.log"

log() { echo "  $*"; }
die() { echo "  [!] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo)."
command -v nginx >/dev/null || die "nginx is not installed."

nginx_version()  { nginx -v 2>&1 | grep -oP 'nginx/\K[0-9]+\.[0-9]+\.[0-9]+'; }
modules_path()   { nginx -V 2>&1 | grep -oP '\-\-modules-path=\K\S+' || echo /usr/lib/nginx/modules; }
stamp_value()    { [[ -f "$STAMP_FILE" ]] && grep -oP "(^| )$1=\K\S+" "$STAMP_FILE" || true; }

MODULE_SO="$(modules_path)/ngx_http_coraza_module.so"

reload_nginx() {
    if nginx -t >/dev/null 2>&1; then
        # after an nginx upgrade with a stale module the service is usually stopped: start it, don't just reload
        if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl start nginx; fi
    else
        log "[!] nginx -t fails; not reloading. Run 'nginx -t' to see why."
        return 1
    fi
}

# True if Coraza was installed by this script and the module no longer fits the installed nginx:
# either the upstream version changed, or nginx itself rejects the module (e.g. changed build flags).
needs_rebuild() {
    local out
    [[ -f "$STAMP_FILE" ]] || return 1
    [[ "$(stamp_value nginx)" == "$(nginx_version)" ]] || return 0
    out=$(nginx -t 2>&1 || true)
    [[ "$out" == *"not binary compatible"* ]]
}

set_engine() {   # $1 = DetectionOnly | On
    [[ -f "$CORAZA_DIR/coraza.conf" ]] || die "$CORAZA_DIR/coraza.conf not found - run the install first."
    sed -i -E "s/^SecRuleEngine .*/SecRuleEngine $1/" "$CORAZA_DIR/coraza.conf"
    log "SecRuleEngine is now: $1"
    reload_nginx
}

cmd_check() {
    local ver built rc=0
    ver=$(nginx_version)
    built=$(stamp_value nginx)
    echo "  nginx version : $ver"
    echo "  module built for nginx : ${built:-not installed}"
    if [[ ! -f "$MODULE_SO" ]]; then echo "  [!] module file missing: $MODULE_SO"; rc=1
    elif [[ "$built" != "$ver" ]]; then echo "  [!] MISMATCH - re-run: sudo $SELF_INSTALL_PATH"; rc=1
    elif ! nginx -t >/dev/null 2>&1; then echo "  [!] nginx -t fails"; rc=1
    else echo "  [ok] module matches nginx and the config tests OK"; fi
    [[ -f "$CORAZA_DIR/coraza.conf" ]] && echo "  engine mode   : $(grep -oP '^SecRuleEngine \K\S+' "$CORAZA_DIR/coraza.conf")"
    exit $rc
}

case "${1:-install}" in
    check)   cmd_check ;;
    detect)  set_engine DetectionOnly; exit 0 ;;
    enforce) set_engine On; exit 0 ;;
    install) ;;
    --schedule)
        # Called from the apt hook (which still holds apt's locks): queue --auto to run a couple of minutes later.
        needs_rebuild || exit 0
        systemd-run --quiet --no-block --on-active=2min --unit=coraza-nginx-rebuild \
            --property=StandardOutput=append:"$BUILD_LOG" --property=StandardError=append:"$BUILD_LOG" \
            "$SELF_INSTALL_PATH" --auto || true
        exit 0
        ;;
    --auto)
        # Queued by --schedule. Do nothing unless we are installed and the module no longer fits nginx.
        needs_rebuild || exit 0
        echo "$(date -Is) Coraza module no longer matches nginx $(nginx_version); rebuilding"
        ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
esac

NGINX_VER="$(nginx_version)"
[[ -n "$NGINX_VER" ]] || die "Could not determine the nginx version."

case "$(uname -m)" in
    x86_64)  GOARCH=amd64 ;;
    aarch64) GOARCH=arm64 ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
esac

echo "=== Coraza for nginx $NGINX_VER (libcoraza $LIBCORAZA_TAG, coraza-nginx $CORAZA_NGINX_TAG, CRS $CRS_TAG) ==="

# --- 1. Build dependencies -------------------------------------------------------------------
echo "--- Installing build dependencies ---"
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=300 install -y -q \
    build-essential git curl ca-certificates rsync python3 \
    autoconf automake libtool pkg-config \
    libpcre2-dev zlib1g-dev libssl-dev libyajl-dev

WORK="$(mktemp -d /var/tmp/coraza-build-XXXXXX)"
cleanup() { chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
export GOCACHE="$WORK/gocache" GOPATH="$WORK/gopath"

# --- 2. Go >= 1.25 (build-time only; removed afterwards with the work dir) -------------------
go_ok() {
    local v
    v=$(GOTOOLCHAIN=local "$1" env GOVERSION 2>/dev/null | sed 's/^go//') || return 1
    [[ -n "$v" ]] && [[ "$(printf '%s\n%s\n' "$MIN_GO" "$v" | sort -V | head -n1)" == "$MIN_GO" ]]
}

GO_BIN=""
for candidate in "$(command -v go 2>/dev/null || true)" /usr/local/go/bin/go; do
    [[ -n "$candidate" && -x "$candidate" ]] && go_ok "$candidate" && { GO_BIN="$candidate"; break; }
done

if [[ -z "$GO_BIN" ]]; then
    echo "--- Downloading Go (system Go is missing or older than $MIN_GO) ---"
    PYCODE='
import json, sys
arch = sys.argv[1]
for rel in json.load(sys.stdin):
    if not rel.get("stable"):
        continue
    for f in rel["files"]:
        if f["os"] == "linux" and f["arch"] == arch and f["kind"] == "archive":
            print(f["filename"], f["sha256"]); sys.exit(0)
sys.exit(1)'
    read -r GO_FILE GO_SHA < <(curl -fsSL --max-time 30 'https://go.dev/dl/?mode=json' | python3 -c "$PYCODE" "$GOARCH") \
        || true
    [[ -n "${GO_FILE:-}" && -n "${GO_SHA:-}" ]] || die "Could not look up the latest Go release from go.dev."
    curl -fsSL --max-time 300 -o "$WORK/$GO_FILE" "https://go.dev/dl/$GO_FILE" || die "Go download failed."
    echo "$GO_SHA  $WORK/$GO_FILE" | sha256sum -c - >/dev/null || die "Go archive checksum mismatch."
    tar -C "$WORK" -xzf "$WORK/$GO_FILE"
    GO_BIN="$WORK/go/bin/go"
    go_ok "$GO_BIN" || die "Downloaded Go is older than $MIN_GO."
fi
GO_DIR="$(dirname "$GO_BIN")"
export PATH="$GO_DIR:$PATH"
log "Using $($GO_BIN version)"

# --- 3. libcoraza ----------------------------------------------------------------------------
echo "--- Building libcoraza $LIBCORAZA_TAG ---"
git clone -q --depth 1 --branch "$LIBCORAZA_TAG" https://github.com/corazawaf/libcoraza "$WORK/libcoraza"
(
    cd "$WORK/libcoraza"
    ./build.sh
    ./configure
    make -j"$(nproc)"
    make install
)
ldconfig
ldconfig -p | grep libcoraza >/dev/null || die "libcoraza.so is not in the linker cache after install."

# --- 4. coraza-nginx module, built against the installed nginx -------------------------------
echo "--- Building coraza-nginx $CORAZA_NGINX_TAG for nginx $NGINX_VER ---"
git clone -q --depth 1 --branch "$CORAZA_NGINX_TAG" https://github.com/corazawaf/coraza-nginx "$WORK/coraza-nginx"
curl -fsSL --max-time 120 -o "$WORK/nginx.tar.gz" "https://nginx.org/download/nginx-$NGINX_VER.tar.gz" \
    || die "Could not download nginx $NGINX_VER source from nginx.org."
tar -C "$WORK" -xzf "$WORK/nginx.tar.gz"

# Reuse the package's configure flags so the module signature matches. Drop the flags that need extra
# dev libraries or don't affect HTTP modules (dynamic modules, mail, stream).
eval "set -- $(nginx -V 2>&1 | sed -n 's/^configure arguments: //p')"
CONFIGURE_ARGS=()
for arg in "$@"; do
    case "$arg" in
        *=dynamic|--add-*module=*|--with-mail*|--with-stream*) ;;
        --with-cc-opt=*) CONFIGURE_ARGS+=("$arg -I/usr/local/include -Wno-error") ;;
        --with-ld-opt=*) CONFIGURE_ARGS+=("$arg -L/usr/local/lib") ;;
        *) CONFIGURE_ARGS+=("$arg") ;;
    esac
done
[[ " ${CONFIGURE_ARGS[*]} " == *" --with-compat "* ]] || CONFIGURE_ARGS+=(--with-compat)

(
    cd "$WORK/nginx-$NGINX_VER"
    ./configure "${CONFIGURE_ARGS[@]}" --add-dynamic-module="$WORK/coraza-nginx"
    make -j"$(nproc)" modules
)
[[ -f "$WORK/nginx-$NGINX_VER/objs/ngx_http_coraza_module.so" ]] || die "Build did not produce ngx_http_coraza_module.so."

# --- 5. Install the module (with rollback if nginx rejects it) -------------------------------
echo "--- Installing module ---"
mkdir -p "$(dirname "$MODULE_SO")" "$STATE_DIR"
[[ -f "$MODULE_SO" ]] && cp -a "$MODULE_SO" "$MODULE_SO.bak"
install -m 0644 "$WORK/nginx-$NGINX_VER/objs/ngx_http_coraza_module.so" "$MODULE_SO.new"
mv -f "$MODULE_SO.new" "$MODULE_SO"
echo "load_module $MODULE_SO;" > "$MODULES_ENABLED_CONF"

if ! nginx -t >/dev/null 2>&1; then
    nginx -t 2>&1 | sed 's/^/    /' >&2 || true
    if [[ -f "$MODULE_SO.bak" ]]; then mv -f "$MODULE_SO.bak" "$MODULE_SO"; else rm -f "$MODULE_SO" "$MODULES_ENABLED_CONF"; fi
    die "nginx rejected the new module; rolled back."
fi
rm -f "$MODULE_SO.bak"
echo "nginx=$NGINX_VER libcoraza=$LIBCORAZA_TAG coraza-nginx=$CORAZA_NGINX_TAG crs=$CRS_TAG built=$(date -Is)" > "$STAMP_FILE"

# --- 6. OWASP Core Rule Set and config (existing config files are never overwritten) ---------
echo "--- Installing OWASP CRS $CRS_TAG ---"
curl -fsSL --max-time 120 -o "$WORK/crs.tar.gz" "https://github.com/coreruleset/coreruleset/archive/refs/tags/$CRS_TAG.tar.gz" \
    || die "Could not download CRS $CRS_TAG."
tar -C "$WORK" -xzf "$WORK/crs.tar.gz"
CRS_SRC="$(find "$WORK" -maxdepth 1 -type d -name 'coreruleset-*' -print -quit)"
[[ -d "$CRS_SRC/rules" ]] || die "CRS archive has no rules/ directory."

mkdir -p "$CORAZA_DIR/crs"
rsync -a --delete "$CRS_SRC/rules/" "$CORAZA_DIR/crs/rules/"
[[ -f "$CORAZA_DIR/crs/crs-setup.conf" ]] || cp "$CRS_SRC/crs-setup.conf.example" "$CORAZA_DIR/crs/crs-setup.conf"

write_if_missing() {   # $1 = path; content on stdin
    if [[ -e "$1" ]]; then cat >/dev/null; log "[=] kept existing $1"; else cat > "$1"; log "[+] wrote $1"; fi
}

write_if_missing "$CORAZA_DIR/coraza.conf" <<'EOF'
# Coraza engine settings. Switch mode with:  install_coraza_nginx.sh detect | enforce
SecRuleEngine DetectionOnly

# Request bodies (keep the limit in line with client_max_body_size in nginx.conf)
SecRequestBodyAccess On
SecRequestBodyLimit 20971520
SecRequestBodyNoFilesLimit 131072
SecRequestBodyInMemoryLimit 131072
SecRequestBodyLimitAction ProcessPartial

# Response bodies are not inspected (saves CPU/memory; disables CRS data-leakage rules)
SecResponseBodyAccess Off

# Log matches of rules that don't set their own action (CRS relies on these)
SecDefaultAction "phase:1,log,auditlog,pass"
SecDefaultAction "phase:2,log,auditlog,pass"

# Parse XML and JSON bodies
SecRule REQUEST_HEADERS:Content-Type "^(?:application(?:/soap\+|/)|text/)xml" \
    "id:200000,phase:1,t:none,t:lowercase,pass,nolog,ctl:requestBodyProcessor=XML"
SecRule REQUEST_HEADERS:Content-Type "^application/json" \
    "id:200001,phase:1,t:none,t:lowercase,pass,nolog,ctl:requestBodyProcessor=JSON"
SecRule REQUEST_HEADERS:Content-Type "^application/[a-z0-9.-]+[+]json" \
    "id:200006,phase:1,t:none,t:lowercase,pass,nolog,ctl:requestBodyProcessor=JSON"
SecRule REQBODY_ERROR "!@eq 0" \
    "id:200002,phase:2,t:none,log,deny,status:400,msg:'Failed to parse request body.',logdata:'%{reqbody_error_msg}',severity:2"

# JSON audit log, written for requests that were blocked (4xx/5xx) or matched a rule
SecAuditEngine RelevantOnly
SecAuditLogRelevantStatus "^(?:5[0-9]{2}|4(?:0[0-35-9]|[1-9][0-9]))$"
SecAuditLogParts ABIJDEFHZ
SecAuditLogType Serial
SecAuditLogFormat JSON
SecAuditLog /var/log/nginx/coraza_audit.json
EOF

write_if_missing "$CORAZA_DIR/before-crs.conf" <<'EOF'
# Your rule exclusions that must load BEFORE the Core Rule Set, e.g.
#   SecRule REQUEST_URI "@beginsWith /api/upload" "id:1000,phase:1,pass,nolog,ctl:ruleRemoveById=920420"
#   SecRule REQUEST_URI "@beginsWith /admin/editor" "id:1001,phase:1,pass,nolog,ctl:ruleRemoveTargetById=942100;ARGS:content"
EOF

write_if_missing "$CORAZA_DIR/after-crs.conf" <<'EOF'
# Your rules and exclusions that must load AFTER the Core Rule Set, e.g.
#   SecRuleRemoveById 949110
EOF

write_if_missing "$CORAZA_DIR/coraza-nginx.conf" <<'EOF'
# Entry point referenced from nginx:  coraza_rules_file /etc/nginx/coraza/coraza-nginx.conf;
Include /etc/nginx/coraza/coraza.conf
Include /etc/nginx/coraza/crs/crs-setup.conf
Include /etc/nginx/coraza/before-crs.conf
Include /etc/nginx/coraza/crs/rules/*.conf
Include /etc/nginx/coraza/after-crs.conf
EOF

# --- 7. Audit log, logrotate, Wazuh, apt hook ------------------------------------------------
[[ -e "$AUDIT_LOG" ]] || install -m 0640 -o www-data -g adm /dev/null "$AUDIT_LOG"

cat > /etc/logrotate.d/coraza-nginx <<EOF
$AUDIT_LOG {
    su www-data adm
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF

if [[ -f /var/ossec/etc/ossec.conf ]] && ! grep -qF "$AUDIT_LOG" /var/ossec/etc/ossec.conf; then
    printf '\n<ossec_config>\n  <localfile>\n    <log_format>json</log_format>\n    <location>%s</location>\n  </localfile>\n</ossec_config>\n' \
        "$AUDIT_LOG" >> /var/ossec/etc/ossec.conf
    systemctl restart wazuh-agent 2>/dev/null || true
    log "[+] Wazuh now monitors $AUDIT_LOG"
fi

# Keep a copy of this script where the apt hook can find it, and rebuild after nginx version changes.
# Post-Invoke runs while apt/dpkg still hold their locks, so the rebuild is scheduled shortly afterwards.
SELF="$(readlink -f "$0")"
[[ "$SELF" == "$SELF_INSTALL_PATH" ]] || install -m 0755 "$SELF" "$SELF_INSTALL_PATH"
cat > /etc/apt/apt.conf.d/99-coraza-nginx <<EOF
DPkg::Post-Invoke { "[ -x $SELF_INSTALL_PATH ] && $SELF_INSTALL_PATH --schedule || true"; };
EOF

reload_nginx || true

echo ""
echo "=== Coraza installed (engine mode: DetectionOnly) ==="
echo "  Enable it per site, inside the server { } block:"
echo "      coraza on;"
echo "      coraza_rules_file $CORAZA_DIR/coraza-nginx.conf;"
echo "  Then: nginx -t && systemctl reload nginx"
echo "  Review $AUDIT_LOG for a couple of weeks, add exclusions to $CORAZA_DIR/before-crs.conf,"
echo "  then run: sudo $SELF_INSTALL_PATH enforce"
