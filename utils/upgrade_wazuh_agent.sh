#!/usr/bin/env bash
# upgrade_wazuh_agent.sh — upgrade the Wazuh agent to a specified version
#
# Usage:
#   sudo ./upgrade_wazuh_agent.sh           # prompts for version
#   sudo ./upgrade_wazuh_agent.sh 4.12.0    # uses specified version
#
# IMPORTANT: The Wazuh agent version must never exceed the manager version.
# Always upgrade the manager first, then run this script on each agent.
# The agent is pinned with apt-mark hold after install to prevent accidental
# auto-upgrades via unattended-upgrades or apt upgrade.
#
set -euo pipefail

# --- Require root ---
if [[ $EUID -ne 0 ]]; then
    echo "[!] This script must be run as root (sudo)." >&2
    exit 1
fi

# --- Check wazuh-agent is installed ---
if ! dpkg -l wazuh-agent &>/dev/null; then
    echo "[!] wazuh-agent is not installed on this host." >&2
    exit 1
fi

# --- Current version ---
CURRENT_VERSION=$(dpkg-query -W -f='${Version}' wazuh-agent 2>/dev/null | grep -oP '^[\d.]+' || echo "unknown")
echo ""
echo "  Current wazuh-agent version : $CURRENT_VERSION"
echo ""

# --- Determine target version ---
if [[ -n "${1:-}" ]]; then
    TARGET_VERSION="$1"
else
    echo "  The agent version must be <= the Wazuh Manager version."
    echo "  There is no way to query the manager version from this host —"
    echo "  check it on the manager server with:"
    echo ""
    echo "    /var/ossec/bin/wazuh-control info | grep VERSION"
    echo ""
    while true; do
        read -rp "  Enter the target Wazuh Agent version (e.g. 4.12.0): " TARGET_VERSION
        if [[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            echo "  [!] Invalid format — please enter a version like 4.12.0"
        fi
    done
fi

# --- Validate format ---
if [[ ! "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "[!] Invalid version format '$TARGET_VERSION' — expected x.y.z (e.g. 4.12.0)" >&2
    exit 1
fi

# --- Already on target? ---
if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" ]]; then
    echo "  Already on $TARGET_VERSION — nothing to do."
    # Ensure it's still pinned even if re-run
    apt-mark hold wazuh-agent &>/dev/null || true
    exit 0
fi

# --- Confirm ---
echo ""
echo "  Upgrade plan:"
echo "    $CURRENT_VERSION  ->  $TARGET_VERSION"
echo ""
echo "  The agent will be stopped, upgraded, and re-pinned with apt-mark hold."
read -rp "  Proceed? (y/N) " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }

# --- Unhold, upgrade, rehold ---
echo ""
echo "  Removing apt hold ..."
apt-mark unhold wazuh-agent

echo "  Installing wazuh-agent=${TARGET_VERSION}-1 ..."
if ! apt-get install -y "wazuh-agent=${TARGET_VERSION}-1"; then
    echo ""
    echo "  [!] Installation failed. Re-pinning current version."
    apt-mark hold wazuh-agent
    exit 1
fi

echo "  Re-pinning wazuh-agent at $TARGET_VERSION ..."
apt-mark hold wazuh-agent

# --- Restart ---
echo "  Restarting wazuh-agent ..."
systemctl restart wazuh-agent

# --- Verify ---
sleep 2
NEW_VERSION=$(dpkg-query -W -f='${Version}' wazuh-agent 2>/dev/null | grep -oP '^[\d.]+' || echo "unknown")
STATUS=$(systemctl is-active wazuh-agent 2>/dev/null || echo "unknown")

echo ""
if [[ "$NEW_VERSION" == "$TARGET_VERSION" && "$STATUS" == "active" ]]; then
    echo "  [V] wazuh-agent upgraded: $CURRENT_VERSION -> $NEW_VERSION (service: $STATUS)"
else
    echo "  [!] Post-upgrade check:"
    echo "      Version : $NEW_VERSION (expected $TARGET_VERSION)"
    echo "      Service : $STATUS"
    echo "      Run 'systemctl status wazuh-agent' for details."
fi
