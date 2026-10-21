#!/usr/bin/env bash
# upgrade_forgejo.sh — upgrade Forgejo to the latest release (or a specified version)
#
# Usage:
#   sudo ./upgrade_forgejo.sh           # upgrades to latest
#   sudo ./upgrade_forgejo.sh 16.0.4    # upgrades to a specific version
#
set -euo pipefail

FORGEJO_FALLBACK_VERSION="17.0.0"
BACKUP_DIR="/var/backups/forgejo"
FORGEJO_BIN="/usr/local/bin/forgejo"
APP_INI="/etc/forgejo/app.ini"

# --- Require root ---
if [[ $EUID -ne 0 ]]; then
    echo "[!] This script must be run as root (sudo)." >&2
    exit 1
fi

# --- Determine target version ---
if [[ -n "${1:-}" ]]; then
    TARGET_VERSION="$1"
    echo "  Target version specified: $TARGET_VERSION"
else
    echo "  Fetching latest Forgejo release ..."
    TARGET_VERSION=$(curl -s --max-time 10 \
        https://codeberg.org/api/v1/repos/forgejo/forgejo/releases/latest 2>/dev/null \
        | jq -r .tag_name 2>/dev/null \
        | sed 's/v//' || true)

    if [[ -z "$TARGET_VERSION" ]]; then
        echo "  [!] Could not fetch latest version — using fallback $FORGEJO_FALLBACK_VERSION"
        TARGET_VERSION="$FORGEJO_FALLBACK_VERSION"
    fi
    echo "  Latest version: $TARGET_VERSION"
fi

# --- Check current version ---
CURRENT_VERSION=$("$FORGEJO_BIN" --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo "unknown")
echo "  Current version: $CURRENT_VERSION"

if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" ]]; then
    echo "  Already on $TARGET_VERSION — nothing to do."
    exit 0
fi

# --- Detect architecture ---
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
DOWNLOAD_URL="https://codeberg.org/forgejo/forgejo/releases/download/v${TARGET_VERSION}/forgejo-${TARGET_VERSION}-linux-${ARCH}"

# --- Back up database ---
echo ""
echo "  Backing up Forgejo database ..."
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

DB_TYPE=$(grep -Po '(?<=^DB_TYPE\s{0,10}=\s{0,10})\S+' "$APP_INI" 2>/dev/null || echo "sqlite3")

case "$DB_TYPE" in
    sqlite3)
        SQLITE_PATH=$(grep -Po '(?<=^PATH\s{0,10}=\s{0,10})\S+' "$APP_INI" 2>/dev/null \
            || echo "/var/lib/forgejo/forgejo.db")
        cp "$SQLITE_PATH" "$BACKUP_DIR/forgejo-${TIMESTAMP}.db"
        echo "  [V] SQLite backup: $BACKUP_DIR/forgejo-${TIMESTAMP}.db"
        ;;
    mysql)
        DB_NAME=$(grep -Po '(?<=^NAME\s{0,10}=\s{0,10})\S+' "$APP_INI")
        mysqldump "$DB_NAME" | gzip > "$BACKUP_DIR/forgejo-${TIMESTAMP}.sql.gz"
        echo "  [V] MySQL backup: $BACKUP_DIR/forgejo-${TIMESTAMP}.sql.gz"
        ;;
    postgres)
        DB_NAME=$(grep -Po '(?<=^NAME\s{0,10}=\s{0,10})\S+' "$APP_INI")
        sudo -u postgres pg_dump "$DB_NAME" | gzip > "$BACKUP_DIR/forgejo-${TIMESTAMP}.sql.gz"
        echo "  [V] PostgreSQL backup: $BACKUP_DIR/forgejo-${TIMESTAMP}.sql.gz"
        ;;
    *)
        echo "  [!] Unknown DB_TYPE '$DB_TYPE' — skipping database backup. Proceed with caution."
        ;;
esac

# --- Download new binary ---
echo ""
echo "  Downloading Forgejo $TARGET_VERSION ($ARCH) ..."
TMP_BIN=$(mktemp /tmp/forgejo-XXXXXX)
if ! wget -q -O "$TMP_BIN" "$DOWNLOAD_URL"; then
    echo "  [!] Download failed: $DOWNLOAD_URL" >&2
    rm -f "$TMP_BIN"
    exit 1
fi

if [[ ! -s "$TMP_BIN" ]]; then
    echo "  [!] Downloaded file is empty — aborting." >&2
    rm -f "$TMP_BIN"
    exit 1
fi

# --- Stop, replace, start ---
echo "  Stopping Forgejo ..."
systemctl stop forgejo

echo "  Installing new binary ..."
install -m 755 "$TMP_BIN" "$FORGEJO_BIN"
rm -f "$TMP_BIN"

echo "  Starting Forgejo ..."
systemctl start forgejo

# --- Verify ---
sleep 2
NEW_VERSION=$("$FORGEJO_BIN" --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo "unknown")
if [[ "$NEW_VERSION" == "$TARGET_VERSION" ]]; then
    echo ""
    echo "  [V] Forgejo upgraded: $CURRENT_VERSION -> $NEW_VERSION"
else
    echo ""
    echo "  [!] Version mismatch after upgrade — expected $TARGET_VERSION, got $NEW_VERSION"
    echo "  Check: systemctl status forgejo"
fi
