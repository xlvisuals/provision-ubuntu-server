#!/usr/bin/env bash
# upgrade_modulejail.sh — re-run modulejail at the latest release (or a specified version)
#
# Usage:
#   sudo ./upgrade_modulejail.sh          # uses latest release
#   sudo ./upgrade_modulejail.sh 1.6.1    # uses a specific version
#
# Modulejail is a one-shot script that blacklists unused kernel modules by writing
# /etc/modprobe.d/modulejail-blacklist.conf. Re-running it regenerates that file
# based on currently loaded modules. Run after adding new services.
#
# The whitelist at /etc/modulejail/whitelist.conf is preserved — do not remove it
# or modulejail may blacklist modules needed by networking, firewall, or IDS.
#
set -euo pipefail

MODULEJAIL_FALLBACK_VERSION="1.6.1"
WHITELIST="/etc/modulejail/whitelist.conf"
BLACKLIST="/etc/modprobe.d/modulejail-blacklist.conf"

# --- Require root ---
if [[ $EUID -ne 0 ]]; then
    echo "[!] This script must be run as root (sudo)." >&2
    exit 1
fi

# --- Warn if whitelist is missing ---
if [[ ! -f "$WHITELIST" ]]; then
    echo "[!] Whitelist not found at $WHITELIST"
    echo "    Modulejail may blacklist modules needed for networking, firewall, or IDS."
    echo "    Check the provision script for the expected whitelist contents."
    read -rp "    Continue anyway? (y/N) " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 1
fi

# --- Determine target version ---
if [[ -n "${1:-}" ]]; then
    TARGET_VERSION="$1"
    echo "  Target version specified: $TARGET_VERSION"
else
    echo "  Fetching latest modulejail release ..."
    TARGET_VERSION=$(curl -sSL --max-time 10 \
        https://api.github.com/repos/jnuyens/modulejail/releases/latest 2>/dev/null \
        | jq -r .tag_name 2>/dev/null \
        | sed 's/v//' || true)

    if [[ -z "$TARGET_VERSION" ]]; then
        echo "  [!] Could not fetch latest version — using fallback $MODULEJAIL_FALLBACK_VERSION"
        TARGET_VERSION="$MODULEJAIL_FALLBACK_VERSION"
    fi
    echo "  Latest version: $TARGET_VERSION"
fi

DOWNLOAD_URL="https://raw.githubusercontent.com/jnuyens/modulejail/v${TARGET_VERSION}/modulejail"

# --- Download ---
echo ""
echo "  Downloading modulejail v$TARGET_VERSION ..."
TMP_SCRIPT=$(mktemp /tmp/modulejail-XXXXXX)
if ! curl -fsSL --max-time 30 "$DOWNLOAD_URL" -o "$TMP_SCRIPT"; then
    echo "  [!] Download failed: $DOWNLOAD_URL" >&2
    rm -f "$TMP_SCRIPT"
    exit 1
fi

if [[ ! -s "$TMP_SCRIPT" ]]; then
    echo "  [!] Downloaded file is empty — aborting." >&2
    rm -f "$TMP_SCRIPT"
    exit 1
fi

# --- Back up existing blacklist ---
if [[ -f "$BLACKLIST" ]]; then
    BACKUP="${BLACKLIST}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$BLACKLIST" "$BACKUP"
    echo "  Existing blacklist backed up to: $BACKUP"
fi

# --- Run ---
echo "  Running modulejail ..."
rm -f "$BLACKLIST"
sh "$TMP_SCRIPT"
rm -f "$TMP_SCRIPT"

# --- Verify ---
if [[ -f "$BLACKLIST" ]]; then
    MODULE_COUNT=$(grep -c '^blacklist' "$BLACKLIST" 2>/dev/null || echo 0)
    echo ""
    echo "  [V] modulejail v$TARGET_VERSION complete — $MODULE_COUNT modules blacklisted"
    echo "  Blacklist written to: $BLACKLIST"
    echo "  A reboot is required for all blacklist changes to take effect."
else
    echo "  [!] Blacklist file not found after run — check for errors above."
fi
